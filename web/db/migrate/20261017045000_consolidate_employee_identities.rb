# frozen_string_literal: true

class ConsolidateEmployeeIdentities < ActiveRecord::Migration[8.1]
  def up
    add_reference :employees, :merged_into, foreign_key: { to_table: :employees }
    add_column :employees, :merged_at, :datetime
    create_table :employee_source_identities do |t|
      t.string :tenant_id, null: false
      t.references :employee, null: false, foreign_key: true
      t.string :source, null: false
      t.string :external_id, null: false
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.boolean :source_active
      t.datetime :source_synced_at
      t.timestamps
      t.index %i[tenant_id source external_id], unique: true, name: 'idx_employee_native_identity'
    end
    execute <<~SQL
      INSERT INTO employee_source_identities
        (tenant_id, employee_id, source, external_id, first_name, last_name, email, phone, source_active, source_synced_at, created_at, updated_at)
      SELECT tenant_id, id, source, external_id, first_name, last_name, email, phone, source_active, source_synced_at, created_at, updated_at
      FROM employees WHERE source IS NOT NULL AND external_id IS NOT NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Employee source identities and consolidation history must be retained.'
  end
end
