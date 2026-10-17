# frozen_string_literal: true

class CreateCtraxLaborShifts < ActiveRecord::Migration[8.1]
  def change
    create_table :ctrax_labor_shifts do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :employee, foreign_key: true
      t.string :source_origin, null: false
      t.string :external_id, null: false
      t.string :store_id
      t.string :user_external_id, null: false
      t.datetime :started_at
      t.datetime :ended_at
      t.decimal :reported_hours, precision: 20, scale: 8
      t.decimal :elapsed_hours, precision: 20, scale: 8
      t.boolean :in_progress, null: false
      t.boolean :verified, null: false
      t.string :status, null: false
      t.string :issue
      t.datetime :last_seen_at, null: false
      t.datetime :source_updated_at
      t.string :original_digest, null: false
      t.string :latest_digest, null: false
      t.text :source_payload, null: false
      t.text :latest_payload, null: false
      t.timestamps
      t.index %i[tenant_id source_origin external_id], unique: true, name: 'idx_ctrax_labor_native'
      t.index %i[tenant_id employee_id started_at], name: 'idx_ctrax_labor_worker'
    end
    create_table :ctrax_labor_observations do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :ctrax_labor_shift, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.datetime :observed_at, null: false
      t.string :digest, null: false
      t.text :payload, null: false
      t.index %i[ctrax_labor_shift_id sequence], unique: true, name: 'idx_ctrax_labor_observation_sequence'
    end
  end
end
