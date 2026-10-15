# frozen_string_literal: true
require 'sqlite3'
require 'json'
require 'fileutils'
require 'digest'
master, output = ARGV
abort 'Snapshot required' unless master && output && !File.basename(master).include?('production')
root = File.dirname(output)
read_results = { baseline: [], candidate: [] }
write_results = { baseline: {}, candidate: {} }
5.times do |round|
  %w[baseline candidate].rotate(round % 2).each do |variant|
    path = File.join(root, "confirm_#{round}_#{variant}.sqlite3")
    FileUtils.cp(master, path)
    db = SQLite3::Database.new(path)
    db.busy_timeout = 5000
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA synchronous=NORMAL')
    db.execute('CREATE INDEX idx_customers_tenant_created_id ON customers(tenant_id, created_at, id)') if variant == 'candidate'
    db.execute('CREATE INDEX idx_sync_runs_tenant_started_at ON "SyncRun"(tenant_id, "startedAt")') if variant == 'candidate'
    db.execute('PRAGMA optimize=0x10002')
    tenant = db.get_first_value('SELECT tenant_id FROM customers GROUP BY tenant_id ORDER BY count(*) DESC LIMIT 1')
    queries = { customers_page: ['SELECT * FROM customers WHERE tenant_id=? ORDER BY created_at DESC, id DESC LIMIT 25', [tenant]], latest_sync: ['SELECT * FROM "SyncRun" WHERE tenant_id=? ORDER BY "startedAt" DESC LIMIT 1', [tenant]] }
    metrics = queries.to_h do |label, (sql, params)|
      5.times { db.execute(sql, params) }
      samples = Array.new(100) do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        db.execute(sql, params)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end.sort
      [label, { p50_ms: samples[49].round(4), p95_ms: samples[94].round(4), digest: Digest::SHA256.hexdigest(JSON.generate(db.execute(sql, params))) }]
    end
    read_results[variant.to_sym] << metrics
    %w[customers SyncRun].each do |table|
      db.results_as_hash = true
      row = db.get_first_row("SELECT * FROM \"#{table}\" WHERE tenant_id=? LIMIT 1", tenant)
      db.results_as_hash = false
      columns = row.keys
      quoted = columns.map { |column| %Q("#{column}") }.join(',')
      sql = "INSERT INTO \"#{table}\" (#{quoted}) VALUES (#{(['?'] * columns.length).join(',')})"
      samples = Array.new(100) do |number|
        probe = row.dup
        probe['id'] = table == 'customers' ? (10_000_000 + round * 1000 + number) : "benchmark-#{round}-#{number}"
        probe['external_id'] = "benchmark-#{round}-#{number}" if table == 'customers'
        probe['status'] = 'success' if table == 'SyncRun'
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        db.execute(sql, columns.map { |column| probe[column] })
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end.sort
      write_results[variant.to_sym][table] ||= []
      write_results[variant.to_sym][table] << { p50_ms: samples[49].round(4), p95_ms: samples[94].round(4) }
    end
    db.close
  end
end
%w[customers_page latest_sync].each do |label|
  hashes = read_results.values.flatten.map { |round| round.fetch(label.to_sym).fetch(:digest) }
  abort 'Read result drift' unless hashes.uniq.length == 1
end
read_results.each_value { |rounds| rounds.each { |round| round.each_value { |value| value.delete(:digest) } } }
File.write(output, JSON.pretty_generate({ method: 'WAL and synchronous=NORMAL; five alternating baseline/candidate rounds; 100 warmed read samples and 100 autocommit inserts per table/round, isolated copied databases only. Inserts clone an existing row with a new primary/unique key; no record values exported.', reads: read_results, writes: write_results }) + "\n")
puts JSON.generate(rounds: 5, output: output, result_equality: true)
