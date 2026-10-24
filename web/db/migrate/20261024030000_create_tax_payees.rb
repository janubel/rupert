# frozen_string_literal: true

# W-9 details for people and businesses that may get a 1099 (#472). The TIN is encrypted by the model.
class CreateTaxPayees < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_payees do |t|
      t.string :tenant_id, null: false
      t.string :payee_key, null: false
      t.string :legal_name, null: false
      t.string :business_name
      t.string :tax_classification, null: false
      t.string :tin_type
      t.text :tin
      t.string :tin_last4
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :state
      t.string :postal_code
      t.string :form_type, null: false
      t.string :misc_box
      t.date :w9_received_on
      t.text :notes
      t.timestamps
    end
    add_index :tax_payees, %i[tenant_id payee_key], unique: true
  end
end
