# frozen_string_literal: true

class CreateEmployeeWorkReports < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_work_reports do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :requester, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :kind, null: false
      t.text :details, null: false
      t.string :status, null: false, default: 'open'
      t.text :response
      t.references :reviewer, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reviewed_at
      t.string :request_key, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[tenant_id employee_id request_key], unique: true, name: 'idx_employee_work_report_request'
      t.index %i[tenant_id status created_at], name: 'idx_employee_work_report_queue'
    end
  end
end
