# frozen_string_literal: true

# Measured on an isolated SER8 SQLite snapshot: these remove a full-table scan
# and temporary ordering trees from the last-sync and customer-list hot paths.
class AddTenantTimelineIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :SyncRun, %i[tenant_id startedAt], name: 'idx_sync_runs_tenant_started_at'
    add_index :customers, %i[tenant_id created_at id], name: 'idx_customers_tenant_created_id'
  end
end
