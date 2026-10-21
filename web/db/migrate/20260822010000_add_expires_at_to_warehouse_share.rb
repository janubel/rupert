# frozen_string_literal: true

# Warehouse share links are gated only by their URL token, which leaks via
# referrers, server logs, and forwarded messages. Give every share an expiry
# (default 30 days from creation) so stale links stop working on their own.
class AddExpiresAtToWarehouseShare < ActiveRecord::Migration[8.1]
  DEFAULT_WINDOW = 30.days

  def change
    add_column :WarehouseShare, :expires_at, :datetime

    # Backfill: existing shares get a window starting from now so nothing that
    # is actively in use breaks mid-sale, but very old links age out too.
    execute <<~SQL
      UPDATE "WarehouseShare"
      SET "expires_at" = datetime('now', '+#{DEFAULT_WINDOW.to_i / 86_400} days')
      WHERE "expires_at" IS NULL AND status = 'active'
    SQL

    add_index :WarehouseShare, %i[token expires_at], name: 'idx_warehouse_share_token_expiry'
  end
end
