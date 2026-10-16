# frozen_string_literal: true

class CreateIrisReports < ActiveRecord::Migration[8.1]
  def change
    create_table :iris_reports do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :api_origin, null: false
      t.string :merchant_number, null: false
      t.string :report_kind, null: false
      t.date :window_from, null: false
      t.date :window_to, null: false
      t.string :status, null: false
      t.text :payload_json, null: false
      t.string :source_digest
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_index :iris_reports, %i[tenant_id api_origin merchant_number report_kind window_from window_to], unique: true, name: 'idx_iris_report_window'
  end
end
