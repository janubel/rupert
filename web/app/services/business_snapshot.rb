# frozen_string_literal: true

require 'json'

# A plain-language, always-current picture of the business: where sales come
# from, what is being sold, where the cash is and who is owed. Read-only; every
# figure is labelled with its source and age, sources are never added together
# across layers, and anything unknown is shown as unknown.
class BusinessSnapshot
  WINDOWS = [30, 90, 365].freeze

  SOURCE_NOTES = {
    'shopify' => ['Shopify', 'Online store orders, imported about every 15 minutes.'],
    'square' => ['Square', 'In-store orders from the older Square setup. Needs a Square access token in Rupert setup to keep importing.'],
    'ctrax' => ['C-Trax', 'Retail point-of-sale daily sales and stock, imported about every 30 minutes.'],
    'swipesimple' => ['SwipeSimple', 'Card-terminal reports, imported by website read about every 30 minutes.'],
    'rupert_pos' => ['Rupert POS', 'Sales rung up in Rupert itself.'],
    'manual' => ['Manual', 'Sales typed in by a person.']
  }.freeze

  attr_reader :generated_at

  def initialize(now: Time.current)
    @generated_at = now
  end

  def to_h
    @to_h ||= { 'generated_at' => generated_at.utc.iso8601, 'timezone' => Time.zone.name, 'version' => File.read(Rails.root.join('..', 'VERSION')).strip,
                'business' => TenantSettings.business_name, 'sales' => sales, 'products' => products, 'cash' => cash,
                'money_out' => money_out, 'vendors' => vendors, 'health' => health }
  rescue Errno::ENOENT
    @to_h = { 'generated_at' => generated_at.utc.iso8601, 'sales' => sales, 'products' => products, 'cash' => cash,
              'money_out' => money_out, 'vendors' => vendors, 'health' => health }
  end

  def to_json(*) = to_h.to_json

  def sales
    ds = DashboardSales.new(days: WINDOWS.max, now: generated_at)
    last_orders = Core::Order.group(:source).maximum(:occurred_at)
    freshness = DailyRegisterSummary.new(day: Date.current.iso8601).source_freshness
    keys = (ds.rows.map { |r| r[:source] } | last_orders.keys | %w[shopify ctrax]).uniq.sort
    {
      'windows' => WINDOWS.to_h do |days|
        since = generated_at.beginning_of_day - (days - 1).days
        [days.to_s, ds.groups(since: since).map { |source, cents, count| { 'source' => source, 'cents' => cents, 'orders' => count } }]
      end,
      'sources' => keys.map do |key|
        label, note = SOURCE_NOTES.fetch(key, [key.humanize, 'Source recorded in imported orders.'])
        last_row = ds.rows.select { |r| r[:source] == key }.map { |r| r[:at] }.max
        { 'key' => key, 'label' => label, 'note' => note, 'last_sale_at' => (last_row || last_orders[key])&.utc&.iso8601,
          'last_import_at' => freshness.dig(key, :finished_at)&.utc&.iso8601 }
      end,
      'note' => 'Sources are separate evidence layers and are listed side by side, not netted. C-Trax and the canonical order store are different systems; check both before concluding a source has stopped.'
    }
  end

  def products
    threshold = TenantSettings.low_stock_threshold_int
    since = generated_at - 90.days
    top = Core::OrderLine.joins(:order).where(orders: { occurred_at: since.., status: %w[paid fulfilled] })
      .group(:name, :sku).sum(:line_cents).sort_by { |_, c| -c }.first(10)
    {
      'active_products' => ShopifyProduct.active.count, 'variants' => ShopifyVariant.count,
      'square_variations' => SquareVariation.count, 'linked_skus' => SkuLink.linked.count,
      'stock_value_cents' => stock_value_cents,
      'low_stock' => ShopifyVariant.where('"inventoryQuantity" > 0 AND "inventoryQuantity" <= ?', threshold).count,
      'out_of_stock' => ShopifyVariant.where('"inventoryQuantity" <= 0').count,
      'low_stock_threshold' => threshold,
      'top_sellers_90d' => top.map { |(name, sku), cents| { 'name' => name, 'sku' => sku, 'cents' => cents } },
      'note' => 'Catalog and stock come from Shopify and Square mirrors. Top sellers use the canonical order store only, so retail sales that arrive through C-Trax are not in this list.'
    }
  end

  # price is a float column in the mirror; convert each row through Money so
  # the total is exact integer cents rather than a rounded Float sum.
  def stock_value_cents
    ShopifyVariant.where.not(price: nil).where.not(inventoryQuantity: nil).pluck(:price, :inventoryQuantity)
      .sum { |price, quantity| Money.cents_from_amount(price).to_i * quantity.to_i }
  end

  def cash
    since = generated_at - 30.days
    tenders = Core::Payment.joins(:order).where(orders: { occurred_at: since.. }, payments: { status: 'completed' }).group('payments.method').sum('payments.amount_cents')
    refunds = Core::Refund.joins(:order).where(orders: { occurred_at: since.. }).sum('refunds.amount_cents')
    deposits = IrisReport.where(report_kind: 'daily_deposits_csv').order(observed_at: :desc).first
    last_line = BankStatementLine.maximum(:posted_on)
    forecast = ReconciliationDocument.where(kind: 'cash_forecast').order(id: :desc).select(:id, :created_at, :period_from).first
    approval = BookApproval.chronological.last
    {
      'tenders_30d' => tenders, 'refunds_30d_cents' => refunds,
      'processor_deposits' => deposits && { 'observed_at' => deposits.observed_at&.utc&.iso8601, 'window_from' => deposits.window_from.to_s, 'window_to' => deposits.window_to.to_s },
      'bank' => { 'statements' => BankStatementLine.distinct.count(:document_id), 'latest_line_on' => last_line&.iso8601, 'lines_waiting' => BankStatementLine.pending.count,
                  'live_connection' => false },
      'cash_forecast' => forecast && { 'retained_at' => forecast.created_at.utc.iso8601, 'baseline' => forecast.period_from.to_s },
      'latest_approval' => approval && { 'period' => "#{approval.period_from}..#{approval.period_to}", 'status' => approval.status, 'by' => approval.approved_by_name,
                                        'at' => approval.approved_at.utc.iso8601 },
      'note' => 'Card and cash receipts here are recorded sales tenders, not bank balances. Rupert has no live bank connection: bank figures exist only if statements were uploaded. Processor deposits are batch reports and are not net bank funding.'
    }
  end

  def money_out
    since = (generated_at - 90.days).to_date
    expenses = Finance::Expense.where(incurred_on: since..)
    payments = Finance::VendorPayment.where(paid_on: since..)
    { 'expenses_90d_cents' => expenses.sum(:amount_cents), 'expenses_90d_count' => expenses.count,
      'by_category' => expenses.group(:category).sum(:amount_cents).sort_by { |_, c| -c }.to_h,
      'vendor_payments_90d_cents' => payments.sum(:amount_cents), 'vendor_payments_90d_count' => payments.count,
      'note' => 'Only money-out that someone entered or confirmed from a bank statement appears here.' }
  end

  def vendors
    rows = Purchasing::Payables.by_vendor
    { 'vendor_count' => Purchasing::Vendor.count, 'open_orders' => Purchasing::PurchaseOrder.where(status: 'ordered').count,
      'owed_cents' => rows.sum { |r| r[:balance_cents] }, 'committed_cents' => rows.sum { |r| r[:committed_cents] },
      'vendors' => rows.first(25).map { |r|
                     { 'name' => r[:vendor].name, 'owed_cents' => r[:owed_cents], 'paid_cents' => r[:paid_cents],
                                              'balance_cents' => r[:balance_cents], 'committed_cents' => r[:committed_cents] } },
      'note' => 'Owed = received purchase orders minus payments entered. Committed = ordered, not yet received.' }
  end

  def health
    check = BooksCheck.new
    chain = BookApproval.verify_chain
    { 'books_check' => check.verdict.to_s, 'fix' => check.summary[:fix], 'watch' => check.summary[:watch], 'ok' => check.summary[:ok],
      'approval_ledger_intact' => chain[:ok], 'approvals' => chain[:count] }
  end
end
