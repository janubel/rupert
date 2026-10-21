# frozen_string_literal: true

# SwipeSimple Reporting -> tax and sales CSVs, stored per day. A re-pull of a
# date range replaces that range; each pull records the range it covered so a
# day with no sales (absent from SwipeSimple's CSV) is told apart from a day
# that was never pulled. New tables only.
class CreateSwipesimpleReportDays < ActiveRecord::Migration[8.1]
  def change
    create_table :swipesimple_tax_days do |t|
      t.string :tenant_id, null: false
      t.string :merchant_account, null: false
      t.date :business_date, null: false
      t.string :tax_rate_label, null: false
      t.decimal :rate_percent, precision: 7, scale: 4
      t.bigint :pre_tax_cents
      t.bigint :tax_cents
      t.bigint :total_cents
      t.string :source_digest, null: false
      t.datetime :pulled_at, null: false
      t.timestamps
      t.index %i[tenant_id merchant_account business_date tax_rate_label], unique: true, name: 'idx_swipesimple_tax_days_unique'
    end

    create_table :swipesimple_sales_days do |t|
      t.string :tenant_id, null: false
      t.string :merchant_account, null: false
      t.date :business_date, null: false
      t.bigint :subtotal_cents
      t.bigint :discounts_cents
      t.bigint :tax_cents
      t.bigint :tips_cents
      t.bigint :refunds_cents
      t.bigint :net_sales_cents
      t.bigint :net_card_cents
      t.bigint :net_cash_cents
      t.string :source_digest, null: false
      t.datetime :pulled_at, null: false
      t.timestamps
      t.index %i[tenant_id merchant_account business_date], unique: true, name: 'idx_swipesimple_sales_days_unique'
    end

    create_table :swipesimple_report_pulls do |t|
      t.string :tenant_id, null: false
      t.string :merchant_account, null: false
      t.string :topic, null: false
      t.date :period_from, null: false
      t.date :period_to, null: false
      t.integer :row_count, null: false
      t.string :source_digest, null: false
      t.text :original_csv, null: false
      t.bigint :reconciliation_document_id
      t.datetime :pulled_at, null: false
      t.timestamps
      t.index %i[tenant_id merchant_account topic period_from], name: 'idx_swipesimple_report_pulls_scope'
    end
  end
end
