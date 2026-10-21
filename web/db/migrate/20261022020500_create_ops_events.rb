# frozen_string_literal: true

# Warnings and errors worth an operator's attention (server errors, slow requests,
# permission denials, rejected forms, failed jobs, sign-in failures). Written by
# OpsLog from already-redacted event fields, repeats counted on one row, pruned
# after RUPERT_OPS_EVENT_DAYS (14). It holds names, codes and counts, never values.
class CreateOpsEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ops_events do |t|
      t.string :kind, null: false
      t.string :category, null: false, default: 'other'
      t.string :level, null: false, default: 'warn'
      t.string :summary, null: false, default: ''
      t.string :fingerprint, null: false
      t.integer :occurrences, null: false, default: 1
      t.string :tenant_id
      t.bigint :user_id
      t.string :request_id
      t.text :data
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.index :last_seen_at
      t.index %i[category last_seen_at]
      t.index %i[fingerprint last_seen_at]
      t.index %i[tenant_id last_seen_at]
    end
  end
end
