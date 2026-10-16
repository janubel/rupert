# frozen_string_literal: true

class CreateSquareTimecards < ActiveRecord::Migration[8.1]
  def change
    create_table :square_timecards do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :employee, foreign_key: true
      t.string :external_id, null: false
      t.string :team_member_id
      t.string :location_id
      t.string :timezone
      t.datetime :started_at
      t.datetime :ended_at
      t.bigint :payable_seconds, null: false, default: 0
      t.bigint :unpaid_break_seconds, null: false, default: 0
      t.integer :hourly_rate_cents
      t.string :currency
      t.string :import_status, null: false
      t.string :issue
      t.integer :source_version
      t.datetime :source_updated_at
      t.string :original_digest
      t.text :source_payload
      t.text :latest_payload
      t.datetime :imported_at
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[tenant_id external_id], unique: true, name: 'idx_square_timecard_native'
      t.index %i[tenant_id employee_id started_at], name: 'idx_square_timecard_worker'
    end
    create_table :square_timecard_days do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :square_timecard, null: false, foreign_key: true
      t.date :worked_on, null: false
      t.integer :payable_seconds, null: false
      t.timestamps
      t.index %i[tenant_id square_timecard_id worked_on], unique: true, name: 'idx_square_timecard_day'
      t.index %i[tenant_id worked_on]
    end
  end
end
