# frozen_string_literal: true

# Deletes mirrored/journal rows past their retention window so fast-growing
# tables (inventory movements, ledger mirror, access/activity logs) don't grow
# without bound. Canonical business data (Core::Order, products, links) is
# never touched — only derived mirrors and logs.
#
# Runs nightly via DataRetentionJob, per tenant.
class DataRetention
  # model => [retention window, timestamp column]. LedgerEntry is kept a full
  # year: it is the re-importable source of truth for order backfills
  # (CanonicalOrderImporter.backfill_from_ledger!).
  POLICIES = {
    'InventoryMovement' => [180.days, 'createdAt'],
    'LedgerEntry' => [365.days, 'occurredAt'],
    'AccessLog' => [90.days, 'created_at'],
    'ActivityLog' => [90.days, 'created_at'],
    'SyncAttempt' => [90.days, 'queued_at']
  }.freeze

  BATCH_SIZE = 5_000

  class << self
    # => { "InventoryMovement" => deleted_count, ... }
    def prune_all!(now: Time.current)
      POLICIES.each_with_object({}) do |(model_name, (window, column)), totals|
        totals[model_name] = prune(model_name.constantize, column: column, older_than: now - window)
      end
    end

    def prune(scope, column:, older_than:, batch_size: BATCH_SIZE)
      total = 0
      loop do
        # Column names come from the POLICIES constant, never user input; they
        # must be quoted because legacy tables use camelCase columns.
        ids = scope.where("\"#{column}\" < ?", older_than).limit(batch_size).pluck(:id)
        break if ids.empty?

        total += scope.where(id: ids).delete_all
        break if ids.size < batch_size
      end
      if total.positive?
        Rails.logger.info("DataRetention: pruned #{total} #{scope.name} rows older than #{older_than.iso8601}")
      end
      total
    end
  end
end
