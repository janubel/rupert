# frozen_string_literal: true

# Shopify (and future providers) retry a webhook on any non-2xx answer and may
# deliver the same event more than once. Record each delivery id so a replay is
# acknowledged without being processed twice, and keep a short history for
# forensics/replay.
class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.string :provider, null: false
      t.string :delivery_id, null: false
      t.string :topic, null: false
      t.string :shop_domain
      t.string :status, null: false, default: 'queued'
      t.string :job_id
      t.datetime :received_at, null: false
      t.timestamps
    end
    add_index :webhook_deliveries, %i[provider delivery_id], unique: true
    add_index :webhook_deliveries, :received_at
  end
end
