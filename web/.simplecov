# frozen_string_literal: true

# Coverage runs only when COVERAGE=1 (CI sets it). Results from the parallel
# test workers are merged into coverage/.resultset.json; bin/check-coverage
# enforces a floor on the sync engine and money paths.
SimpleCov.start 'rails' do
  enable_coverage :branch
  add_group 'Sync engine', %w[app/services/sync_engine.rb app/services/catalog_syncer.rb app/services/square_syncer.rb
    app/services/shopify_client.rb app/services/square_client.rb app/services/http_retry.rb app/services/ledger_importer.rb
    app/services/canonical_order_importer.rb app/services/inventory_writer.rb app/jobs/sync_job.rb app/jobs/sync_scheduler_job.rb]
  add_group 'Money', %w[app/services/money.rb app/modules/core/order.rb app/modules/core/refund.rb]
  add_group 'Webhooks', %w[app/controllers/webhooks app/controllers/concerns/webhooks app/jobs/customers_redact_job.rb
    app/jobs/customers_data_request_job.rb app/jobs/shop_redact_job.rb app/jobs/app_uninstalled_job.rb app/models/webhook_delivery.rb]
  add_filter %w[/test/ /config/ /db/ /vendor/]
  minimum_coverage 0 # the floor is enforced per critical file by bin/check-coverage
end
