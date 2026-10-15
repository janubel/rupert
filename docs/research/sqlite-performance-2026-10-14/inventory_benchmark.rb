require 'json'
require 'digest'
Rails.logger.level = Logger::WARN
Rails.cache = ActiveSupport::Cache::MemoryStore.new
Current.tenant = Tenant.unscoped.first
original = InventoryController.instance_method(:variant_stock_map)
load ARGV.fetch(0)
candidate = InventoryController.instance_method(:variant_stock_map)
results = {}
reference = nil
{ baseline: original, candidate: candidate }.each do |name, method|
  samples = []
  7.times do |iteration|
    queries = 0
    variant_queries = 0
    map = nil
    products = nil
    collector = lambda do |*args|
      payload = args.last
      next if payload[:name] == 'SCHEMA' || payload[:cached]
      queries += 1 if payload[:sql].start_with?('SELECT')
      variant_queries += 1 if payload[:sql].match?(/SELECT .*FROM "ShopifyVariant"/)
    end
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(collector, 'sql.active_record') do
        products = ShopifyProduct.order(title: :asc).limit(40)
        products = products.preload(:variants) if name == :candidate
        map = method.bind(InventoryController.new).call(products)
        products.each { |product| product.variants.sort_by(&:title) }
      end
    end
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    digest = Digest::SHA256.hexdigest(JSON.generate(map.as_json.sort_by { |id, _| id }))
    reference ||= digest
    abort 'Inventory result drift' unless digest == reference
    samples << { elapsed_ms: elapsed.round(3), select_queries: queries, variant_queries: variant_queries, products: products.length } if iteration >= 2
  end
  results[name] = samples
end
puts JSON.generate(method: 'Seven cold-object/warm-database inventory assembly trials on a private snapshot; first two discarded. Includes stock-map calculation and variant traversal, not HTTP rendering. Query cache disabled; result digest identical.', results: results)
