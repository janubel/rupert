# frozen_string_literal: true

# Cash flow for a date range: what came into and left the bank, what was sold,
# what was recorded as spent, and where things stand. Reads bank statement lines,
# canonical sales (through DashboardSales, so the figures agree with the home
# dashboard), recorded expenses and vendor payments. Nothing here posts, matches
# or infers: a processor payout is not a second sale, a transfer is not an
# expense, and an unverified balance is unavailable, not zero.
class CashFlowReport
  Error = Class.new(ArgumentError)

  PRESETS = { '30d' => 'Last 30 days', '90d' => 'Last 90 days', 'ytd' => 'This year', '12m' => 'Last 12 months' }.freeze
  CHANNEL_LIMIT = 4 # categorical slots; the tail folds into Other
  EVENT_LIMIT = 12

  attr_reader :from, :to, :account, :range_key, :today

  # Params → report. A named range wins over dates; bad dates fall back to the last 30 days.
  def self.from_params(params, today: Date.current)
    key = params[:range].to_s
    from = parse_date(params[:from])
    to = parse_date(params[:to])
    if PRESETS.key?(key) || from.nil? || to.nil?
      key = PRESETS.key?(key) ? key : '30d'
      from, to = window(key, today)
    else
      key = 'custom'
    end
    new(from: from, to: to, account: params[:account].presence, range_key: key, today: today)
  end

  def self.window(key, today)
    case key
    when '90d' then [today - 89, today]
    when 'ytd' then [today.beginning_of_year, today]
    when '12m' then [(today - 11.months).beginning_of_month, today]
    else [today - 29, today]
    end
  end

  def self.parse_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def initialize(from:, to:, account: nil, range_key: 'custom', today: Date.current)
    raise Error, 'End date must be on or after the start date.' if to < from
    raise Error, 'Choose a range of three years or less.' if (to - from) > 1096

    @from = from
    @to = to
    @today = today
    @range_key = range_key
    @accounts = BankStatementLine.distinct.order(:account_label).pluck(:account_label)
    raise Error, 'Choose a bank account from the list.' if account.present? && !@accounts.include?(account)

    @account = account
  end

  def accounts = @accounts
  def span_days = (to - from).to_i + 1
  def range_label = range_key == 'custom' ? "#{from.strftime('%b %-d, %Y')} – #{to.strftime('%b %-d, %Y')}" : PRESETS.fetch(range_key)

  # --- Buckets: daily up to 45 days, weekly up to 200, monthly beyond ---------

  def bucket = span_days <= 45 ? :day : span_days <= 200 ? :week : :month

  def bucket_starts
    @bucket_starts ||= case bucket
    when :day then (from..to).to_a
    when :week then (from..to).select { |d| d == from || d.monday? }
    else (from..to).select { |d| d == from || d.day == 1 }
    end
  end

  def bucket_labels
    bucket_starts.map { |d| bucket == :month ? d.strftime('%b %Y') : d.strftime('%b %-d') }
  end

  def bucket_index(date)
    date = date.to_date
    idx = bucket_starts.rindex { |start| start <= date }
    idx.nil? ? nil : idx
  end

  # --- Bank: the real cash movement ---------------------------------------------

  def bank_lines
    scope = BankStatementLine.where(posted_on: from..to)
    account ? scope.where(account_label: account) : scope
  end

  # [posted_on, amount_cents, review_category] once; everything bank-related derives from it.
  def bank_rows
    @bank_rows ||= bank_lines.pluck(:posted_on, :amount_cents, :review_category)
  end

  def cash_in_cents = bank_rows.sum { |_, cents, _| cents.positive? ? cents : 0 }
  def cash_out_cents = bank_rows.sum { |_, cents, _| cents.negative? ? -cents : 0 }
  def net_cents = cash_in_cents - cash_out_cents
  def bank_line_count = bank_rows.size
  def bank_data_through = @bank_data_through ||= bank_lines.maximum(:posted_on)

  def bank_series
    @bank_series ||= begin
      ins = Array.new(bucket_starts.size, 0)
      outs = Array.new(bucket_starts.size, 0)
      bank_rows.each do |date, cents, _|
        i = bucket_index(date) or next
        cents.positive? ? ins[i] += cents : outs[i] += -cents
      end
      net = ins.zip(outs).map { |a, b| a - b }
      running = 0
      cumulative = net.map { |n| running += n }
      { in: ins, out: outs, net: net, cumulative: cumulative }
    end
  end

  def processor_deposits_cents = bank_rows.sum { |_, cents, cat| cents.positive? && cat == 'processor_deposit' ? cents : 0 }

  # Money out of the bank by the reviewer's category; undecided lines are their own bucket.
  def bank_out_by_type
    totals = Hash.new(0)
    bank_rows.each { |_, cents, cat| totals[cat.presence || 'undecided'] += -cents if cents.negative? }
    totals.sort_by { |_, cents| -cents }.map { |cat, cents| [cat == 'undecided' ? 'Not yet reviewed' : BankStatementLine.new(review_category: cat).review_category_label, cents] }
  end

  def pending_count = @pending_count ||= bank_lines.pending.count
  def flagged_count = @flagged_count ||= bank_lines.pending.flagged.count

  # --- Sales: what was sold (not what was deposited) ------------------------------

  def sales
    @sales ||= DashboardSales.new(days: (today - from).to_i + 1, now: Time.current)
  end

  def sales_rows
    @sales_rows ||= sales.rows(since: from.in_time_zone.beginning_of_day, until_time: to.in_time_zone.end_of_day)
  end

  def sales_cents = sales_rows.sum { |row| row[:cents] }
  def sales_count = sales_rows.size
  def sales_warnings = sales.warnings

  def refunds_cents
    @refunds_cents ||= Core::Refund.where(refunded_at: from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day).sum(:amount_cents)
  end

  # Each selling channel keeps one colour slot for good (fixed order below), so a
  # channel never changes colour when another one overtakes it. The top channels
  # by total are shown; any beyond CHANNEL_LIMIT fold into Other (muted).
  CHANNEL_SLOTS = %w[shopify square ctrax swipesimple rupert_pos pos manual].freeze

  def channel_series
    @channel_series ||= begin
      totals = Hash.new(0)
      sales_rows.each { |row| totals[row[:source]] += row[:cents] }
      ranked = totals.sort_by { |source, cents| [-cents, CHANNEL_SLOTS.index(source) || CHANNEL_SLOTS.size] }.map(&:first)
      shown = ranked.first(ranked.size > CHANNEL_LIMIT ? CHANNEL_LIMIT - 1 : CHANNEL_LIMIT)
      shown = shown.sort_by { |source| CHANNEL_SLOTS.index(source) || CHANNEL_SLOTS.size }
      series = shown.map do |source|
        { key: source, name: DashboardSales::LABELS.fetch(source, source.to_s.humanize), slot: (CHANNEL_SLOTS.index(source) || CHANNEL_SLOTS.size) % CHANNEL_LIMIT + 1,
          values: Array.new(bucket_starts.size, 0) }
      end
      series << { key: 'other', name: 'Other', slot: 0, values: Array.new(bucket_starts.size, 0) } if ranked.size > shown.size
      by_key = series.index_by { |entry| entry[:key] }
      sales_rows.each do |row|
        i = bucket_index(row[:at].in_time_zone.to_date) or next
        (by_key[row[:source]] || by_key['other'])[:values][i] += row[:cents]
      end
      series.each { |entry| entry[:total_cents] = entry[:values].sum }
    end
  end

  def sales_series
    @sales_series ||= begin
      series = Array.new(bucket_starts.size, 0)
      sales_rows.each { |row| (i = bucket_index(row[:at].in_time_zone.to_date)) && series[i] += row[:cents] }
      series
    end
  end

  # --- Spend: what was recorded, by hand or from the bank review -------------------

  def expenses = Finance::Expense.where(incurred_on: from..to)
  def vendor_payments = Finance::VendorPayment.where(paid_on: from..to)
  def expense_cents = @expense_cents ||= expenses.sum(:amount_cents)
  def vendor_payment_cents = @vendor_payment_cents ||= vendor_payments.sum(:amount_cents)
  def spend_cents = expense_cents + vendor_payment_cents

  def spend_by_category
    rows = expenses.group(:category).sum(:amount_cents).map { |cat, cents| [Finance::ExpenseCategory.label_for(cat), cents] }
    rows << ['Vendor payments', vendor_payment_cents] if vendor_payment_cents.positive?
    rows.sort_by { |_, cents| -cents }
  end

  def spend_series
    @spend_series ||= begin
      series = Array.new(bucket_starts.size, 0)
      expenses.pluck(:incurred_on, :amount_cents).each { |d, c| (i = bucket_index(d)) && series[i] += c }
      vendor_payments.pluck(:paid_on, :amount_cents).each { |d, c| (i = bucket_index(d)) && series[i] += c }
      series
    end
  end

  # --- Comparison with the window just before this one -----------------------------

  def previous
    @previous ||= CashFlowReport.new(from: from - span_days, to: from - 1, account: account, range_key: 'custom', today: today)
  end

  def kpis
    @kpis ||= {
      cash_in: { label: 'Into the bank', cents: cash_in_cents, previous_cents: previous.cash_in_cents, series: bank_series[:in], good: :up },
      cash_out: { label: 'Out of the bank', cents: cash_out_cents, previous_cents: previous.cash_out_cents, series: bank_series[:out], good: :down },
      net: { label: 'Net cash flow', cents: net_cents, previous_cents: previous.net_cents, series: bank_series[:net], good: :up },
      sales: { label: 'Sales taken', cents: sales_cents, previous_cents: previous.sales_cents, series: sales_series, good: :up, count: sales_count },
      spend: { label: 'Spend recorded', cents: spend_cents, previous_cents: previous.spend_cents, series: spend_series, good: :down }
    }
  end

  # --- Position: where cash stands and how long it lasts at this pace ----------------

  def statement_balance
    return @statement_balance if defined?(@statement_balance)

    @statement_balance = begin
      label = account || accounts.first
      label ? BookkeepingOverview.new(account: label).statement_balance : nil
    rescue BookkeepingOverview::Error
      nil
    end
  end

  def average_daily_net_cents = span_days.zero? ? 0 : net_cents / span_days

  # Days of cash left at this range's pace when net is negative and a verified balance exists.
  def runway_days
    return nil unless statement_balance && average_daily_net_cents.negative?

    (statement_balance[:cents].to_f / -average_daily_net_cents).floor
  end

  def latest_forecast = @latest_forecast ||= CashForecastScenario.retained(limit: 1).first

  # The retained cash forecast's weeks that start after this range ends, as a dashed
  # continuation of the running net: the scenario's own receipts less payments per
  # week, added to the last actual running net. Nothing is predicted here; these are
  # the owner's entered assumptions, shown so the chart can look past today.
  def forecast_series
    @forecast_series ||= begin
      doc = latest_forecast
      data = doc ? JSON.parse(doc.original_bytes) : {}
      future = Array(data['rows']).select { |row| Date.iso8601(row['from'].to_s) > to }
      running = bank_series[:cumulative].last || 0
      labels = future.map { |row| "Wk of #{Date.iso8601(row['from']).strftime('%b %-d')}" }
      net = future.map { |row| row['receipts_cents'].to_i - row['payments_cents'].to_i }
      { labels: labels, net: net, cumulative: net.map { |n| running += n }, document_id: doc&.id,
        as_of: (Date.iso8601(data['as_of'].to_s) if data['as_of']) }
    rescue JSON::ParserError, Date::Error, TypeError
      { labels: [], net: [], cumulative: [], document_id: doc&.id, as_of: nil }
    end
  end

  # --- Live feed: the newest money events across every source ------------------------

  def recent_events(limit: EVENT_LIMIT)
    events = []
    Core::Payment.completed.joins(:order).order(paid_at: :desc).limit(limit)
      .pluck(:paid_at, :amount_cents, :method, Arel.sql('orders.source'), Arel.sql('orders.order_number')).each do |at, cents, method, source, number|
      events << { at: at, kind: 'sale', label: "#{DashboardSales::LABELS.fetch(source, source.to_s.humanize)} sale#{number.present? ? " ##{number}" : ''}",
                  detail: method.to_s.humanize, cents: cents }
    end
    BankStatementLine.order(posted_on: :desc, id: :desc).limit(limit).each do |line|
      events << { at: line.posted_on.in_time_zone.end_of_day, kind: line.money_in? ? 'bank_in' : 'bank_out', label: line.description.to_s.truncate(60),
                  detail: "#{line.account_label} · #{line.pending? ? 'needs a decision' : line.review_category_label}", cents: line.amount_cents, id: line.id, document_id: line.document_id }
    end
    Finance::Expense.order(created_at: :desc).limit(limit).each do |expense|
      events << { at: expense.created_at, kind: 'expense', label: expense.payee.presence || expense.category_label, detail: "Expense · #{expense.category_label}", cents: -expense.amount_cents, id: expense.id }
    end
    Finance::VendorPayment.includes(:vendor).order(created_at: :desc).limit(limit).each do |payment|
      events << { at: payment.created_at, kind: 'vendor_payment', label: payment.vendor&.name.presence || 'Vendor payment', detail: 'Vendor payment', cents: -payment.amount_cents, id: payment.id }
    end
    events.sort_by { |event| -event[:at].to_i }.first(limit)
  end

  def last_sync_at = @last_sync_at ||= SyncRun.where.not(finishedAt: nil).maximum(:finishedAt)

  # --- JSON for the page's live refresh -------------------------------------------------

  def to_h
    {
      generated_at: Time.current.iso8601,
      range: { key: range_key, label: range_label, from: from.iso8601, to: to.iso8601, bucket: bucket.to_s, labels: bucket_labels, account: account },
      kpis: kpis.transform_values { |k| k.except(:good).merge(good: k[:good].to_s) },
      bank: bank_series.merge(line_count: bank_line_count, through: bank_data_through&.iso8601, pending: pending_count, flagged: flagged_count),
      channels: channel_series,
      forecast: forecast_series.merge(as_of: forecast_series[:as_of]&.iso8601),
      spend: spend_by_category.map { |label, cents| { label: label, cents: cents } },
      bank_out: bank_out_by_type.map { |label, cents| { label: label, cents: cents } },
      deposits: { sales_cents: sales_cents, refunds_cents: refunds_cents, processor_deposits_cents: processor_deposits_cents },
      position: { balance: statement_balance && { cents: statement_balance[:cents], currency: statement_balance[:currency], date: statement_balance[:date].iso8601 },
                  average_daily_net_cents: average_daily_net_cents, runway_days: runway_days },
      events: recent_events.map { |e| e.merge(at: e[:at].iso8601) },
      warnings: sales_warnings,
      last_sync_at: last_sync_at&.iso8601
    }
  end
end
