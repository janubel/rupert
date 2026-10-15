# frozen_string_literal: true
require 'sqlite3'
require 'json'
require 'thread'
root, output = ARGV
abort 'Private benchmark directory required' unless root && output
results = {}
[1, 3].each do |writers|
  path = File.join(root, "contention_#{writers}.sqlite3")
  abort 'Refusing to overwrite an existing benchmark' if File.exist?(path)
  db = SQLite3::Database.new(path)
  db.execute('PRAGMA journal_mode=WAL')
  db.execute('CREATE TABLE probe(id INTEGER PRIMARY KEY, quantity INTEGER)')
  db.execute('INSERT INTO probe VALUES(1,0)')
  db.close
  gate = Queue.new
  metrics = Queue.new
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  threads = Array.new(writers + 4) do |index|
    Thread.new do
      connection = SQLite3::Database.new(path)
      connection.busy_handler_timeout = 5000
      connection.execute('PRAGMA synchronous=NORMAL')
      gate.pop
      latencies = []
      busy = 0
      operations = index < writers ? 300 / writers : 300
      operations.times do
        before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          if index < writers
            connection.transaction(:immediate) do
              connection.execute('UPDATE probe SET quantity=quantity+1 WHERE id=1')
              sleep 0.001
            end
          else
            connection.execute('SELECT quantity FROM probe WHERE id=1')
          end
          latencies << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - before) * 1000
        rescue SQLite3::BusyException
          busy += 1
        end
      end
      metrics << { writer: index < writers, busy: busy, samples: latencies }
      connection.close
    end
  end
  (writers + 4).times { gate << true }
  threads.each(&:value)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  all = Array.new(writers + 4) { metrics.pop }
  writes = all.select { |item| item[:writer] }.flat_map { |item| item[:samples] }.sort
  reads = all.reject { |item| item[:writer] }.flat_map { |item| item[:samples] }.sort
  connection = SQLite3::Database.new(path, readonly: true)
  results[writers] = { writer_connections: writers, reader_connections: 4, transactions: writes.length, busy_errors: all.sum { |item| item[:busy] }, elapsed_ms: (elapsed * 1000).round(2), write_p95_ms: writes[(writes.length * 0.95).ceil - 1].round(3), write_max_ms: writes.last.round(3), read_p95_ms: reads[(reads.length * 0.95).ceil - 1].round(3), final_counter: connection.get_first_value('SELECT quantity FROM probe WHERE id=1') }
  connection.close
end
File.write(output, JSON.pretty_generate({ method: 'Synthetic WAL/NORMAL database, Rails-style Ruby busy handler (5000 ms), 300 total transactions with 1 ms deliberate lock hold, four concurrent readers. One and three writer connections; not an application or production load test.', results: results }) + "\n")
puts JSON.generate(results)
