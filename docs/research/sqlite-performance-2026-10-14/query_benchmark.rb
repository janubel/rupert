# frozen_string_literal: true

require 'sqlite3'
require 'json'
require 'digest'
require 'fileutils'
require 'time'

# Input must be a private, quiescent snapshot, never the active production DB.
master, output = ARGV
abort 'Usage: query_benchmark.rb snapshot.sqlite3 output.json' unless master && output
abort 'Refusing a production database path' if File.basename(master).include?('production')
abort 'Snapshot must not have a live WAL' if File.exist?("#{master}-wal") && File.size("#{master}-wal").positive?

source = SQLite3::Database.new(master, readonly: true)
tenant = source.get_first_value('SELECT tenant_id FROM orders GROUP BY tenant_id ORDER BY count(*) DESC LIMIT 1')
abort 'No tenant data to benchmark' unless tenant
customer = source.get_first_value('SELECT customer_id FROM orders WHERE tenant_id=? AND customer_id IS NOT NULL GROUP BY customer_id ORDER BY count(*) DESC LIMIT 1', tenant)
sku = source.get_first_value('SELECT sku FROM "ShopifyVariant" WHERE tenant_id=? AND length(sku)>=3 LIMIT 1', tenant).to_s
term = sku[/[[:alnum:]]{3,}/].to_s[0, 3]
cutoff = (Time.now.utc - 30 * 86_400).strftime('%F %T')
counts = %w[orders customers ShopifyProduct ShopifyVariant InventoryMovement SyncRun].to_h do |table|
  [table, source.get_first_value("SELECT count(*) FROM \"#{table}\" WHERE tenant_id=?", tenant)]
end
queries = {
  'inventory_page' => ['SELECT * FROM "ShopifyProduct" WHERE tenant_id=? ORDER BY title LIMIT 40', [tenant]],
  'customers_page' => ['SELECT * FROM customers WHERE tenant_id=? ORDER BY created_at DESC, id DESC LIMIT 25', [tenant]],
  'customer_history' => ['SELECT * FROM orders WHERE tenant_id=? AND customer_id=? ORDER BY occurred_at DESC, id DESC LIMIT 50', [tenant, customer]],
  'dashboard_30d_total' => ["SELECT sum(gross_cents) FROM orders WHERE tenant_id=? AND status IN ('paid','fulfilled') AND occurred_at>=?", [tenant, cutoff]],
  'dashboard_30d_sources' => ["SELECT source, sum(gross_cents), count(*) FROM orders WHERE tenant_id=? AND status IN ('paid','fulfilled') AND occurred_at>=? GROUP BY source", [tenant, cutoff]],
  'movements_all_sources' => ['SELECT * FROM "InventoryMovement" WHERE tenant_id=? AND "createdAt">=? ORDER BY "createdAt" DESC LIMIT 50', [tenant, cutoff]],
  'latest_sync' => ['SELECT * FROM "SyncRun" WHERE tenant_id=? ORDER BY "startedAt" DESC LIMIT 1', [tenant]]
}
if term.length >= 3
  queries['sku_fts'] = ['SELECT id FROM "ShopifyVariant" WHERE tenant_id=? AND rowid IN (SELECT rowid FROM rupert_shopifyvariant_fts WHERE rupert_shopifyvariant_fts MATCH ?) ORDER BY sku LIMIT 8', [tenant, %Q("#{term}")]]
end
indexes = {
  'customers_created' => 'CREATE INDEX bench_customers_created ON customers(tenant_id, created_at, id)',
  'orders_customer_time' => 'CREATE INDEX bench_orders_customer_time ON orders(tenant_id, customer_id, occurred_at, id)',
  'orders_status_time' => 'CREATE INDEX bench_orders_status_time ON orders(tenant_id, status, occurred_at)',
  'products_title' => 'CREATE INDEX bench_products_title ON "ShopifyProduct"(tenant_id, title)',
  'movements_time' => 'CREATE INDEX bench_movements_time ON "InventoryMovement"(tenant_id, "createdAt")',
  'sync_started' => 'CREATE INDEX bench_sync_started ON "SyncRun"(tenant_id, "startedAt")'
}
source.close
variants = { 'baseline' => [] }.merge(indexes.transform_values { |sql| [sql] })
reference = {}
results = {}
variants.each do |name, ddls|
  path = File.join(File.dirname(output), "#{name}.sqlite3")
  FileUtils.cp(master, path)
  db = SQLite3::Database.new(path)
  db.busy_timeout = 5000
  ddls.each { |sql| db.execute(sql) }
  db.execute('PRAGMA optimize=0x10002')
  results[name] = queries.to_h do |label, (sql, params)|
    rows = db.execute(sql, params)
    digest = Digest::SHA256.hexdigest(JSON.generate(rows.sort_by { |row| JSON.generate(row) }))
    reference[label] ||= digest
    abort "Result drift for #{name}/#{label}" unless digest == reference[label]
    5.times { db.execute(sql, params) }
    samples = Array.new(60) do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      db.execute(sql, params)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end.sort
    plan = db.execute("EXPLAIN QUERY PLAN #{sql}", params).map(&:last)
    [label, { p50_ms: samples[29].round(4), p95_ms: samples[56].round(4), rows: rows.length, plan: plan }]
  end
  db.close
end
receipt = { recorded_at: Time.now.utc.iso8601, sqlite_version: SQLite3::SQLITE_VERSION, repetitions: 60, warmups: 5, table_counts: counts, method: 'Single-process warm SQL timings on separate copies of one live snapshot, local storage, no production queries or writes during measurements. Not HTTP latency or a concurrent load test. Every query result was compared by digest across candidates; no row contents or search values are exported.', results: results }
File.write(output, JSON.pretty_generate(receipt) + "\n")
puts JSON.generate(output: output, variants: results.length, queries: queries.length, result_equality: true)
