# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'

# One SwipeSimple business day (America/New_York) for the daily close page.
#
# Reads only stored native website/CSV exports (latest observation per
# transaction) and stored NAB / IRIS deposit snapshots. Nothing here contacts a
# vendor or writes sales, ledger, deposit or bank records.
#
# Amounts stay in integer cents. Unknown values (tips, deposit currency,
# coverage) stay nil and are shown as "Unknown", never as zero.
class SwipesimpleDayClose
  ZONE = 'America/New_York'
  EXCLUDED_STATUSES = %w[Declined Voided Errored Canceled].freeze
  # Flag the day when at least this share of attempts did not approve, once
  # there are enough attempts for the share to mean something.
  DECLINE_SHARE_FLAG = 0.05
  DECLINE_MIN_ATTEMPTS = 10
  DEPOSIT_KINDS = %w[deposits daily_deposits_csv].freeze
  # Card sales fund on a later date; look this many calendar days ahead
  # (covers a weekend plus a holiday).
  FUNDING_LAG_DAYS = 4

  Group = Struct.new(:account, :currency, :tender, :sale_count, :sale_cents, :refund_count, :refund_cents, :net_cents,
    :tip_cents, :missing_tip_rows, :declined_count, :voided_count, :other_excluded_count, keyword_init: true)
  Deposit = Struct.new(:merchant_label, :report_kind, :observed_at, :records, :amount_cents, :currency, :partial_window, keyword_init: true)
  Check = Struct.new(:key, :level, :message, keyword_init: true)
  DepositMatch = Struct.new(:deposit_date, :records, :amount_cents, :currency, :business_days, :card_net_by_day,
    :card_net_cents, :difference_cents, keyword_init: true)

  attr_reader :date

  def initialize(date)
    @date = date.is_a?(Date) ? date : Date.iso8601(date.to_s)
  end

  def window
    @window ||= begin
      start = ActiveSupport::TimeZone[ZONE].local(date.year, date.month, date.day)
      start...ActiveSupport::TimeZone[ZONE].local((date + 1).year, (date + 1).month, (date + 1).day)
    end
  end

  # Latest observation of every transaction that happened during the day.
  def rows
    @rows ||= SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' })
      .where(occurred_at: window).includes(:swipesimple_export)
      .order(:occurred_at, :id).to_a
  end

  def approved
    rows.select { |row| row.status == 'Approved' }
  end

  def excluded
    rows.reject { |row| row.status == 'Approved' }
  end

  def groups
    @groups ||= rows.group_by { |row| [row.swipesimple_export.merchant_account, row.swipesimple_export.currency, row.tender.presence || 'unknown'] }
      .sort_by { |key, _| key.map(&:to_s) }
      .map { |(account, currency, tender), list| build_group(account, currency, tender, list) }
  end

  # Cash / card / unknown net per account and currency. Tenders are never
  # added across currencies.
  def tender_split
    @tender_split ||= groups.group_by { |group| [group.account, group.currency] }.map do |(account, currency), list|
      by_tender = list.to_h { |group| [group.tender, group.net_cents] }
      { account: account, currency: currency, cash: by_tender['cash'], card: by_tender['card'], unknown: by_tender['unknown'],
        total: list.sum(&:net_cents) }
    end
  end

  # Card net in USD across accounts (the only currency the importer accepts).
  def card_net_cents
    cards = groups.select { |group| group.tender == 'card' && group.currency == 'USD' }
    cards.empty? ? nil : cards.sum(&:net_cents)
  end

  def unknown_tip_rows
    approved.select { |row| row.tip_cents.nil? }
  end

  # Invoices created on this day in the latest full invoice snapshot. The
  # native invoice export has no payment date, so "paid today" is unknowable.
  def invoices
    @invoices ||= SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'invoices' })
      .where(occurred_at: window).includes(:swipesimple_export).order(:occurred_at, :id).to_a
  end

  # Approved refunds on this day, each with the matching sale when the same
  # source transaction number has a Sale observation.
  def refunds
    @refunds ||= begin
      list = approved.select { |row| row.transaction_type == 'Refund' }
      identities = list.to_h { |row| [row.id, sale_identity(row)] }
      sales = identities.values.any? ? SwipesimpleReportRow.latest.where(identity: identities.values).includes(:swipesimple_export).index_by(&:identity) : {}
      list.map do |row|
        sale = sales[identities[row.id]]
        { row: row, sale: sale, earlier_day: sale && sale.occurred_at < window.begin }
      end
    end
  end

  def latest_transaction_export
    @latest_transaction_export ||= SwipesimpleExport.where(kind: 'transactions').order(:exported_at, :id).last
  end

  def connection
    @connection ||= PosConnection.find_by(provider: 'swipesimple')
  end

  # :covered when a stored export was taken after the day ended; :partial when
  # the newest export was taken during the day; :missing when none is newer
  # than the day's start; :future for days that have not started.
  def coverage
    return :future if window.begin > Time.current
    return :missing unless latest_transaction_export && latest_transaction_export.exported_at >= window.begin
    return :partial if latest_transaction_export.exported_at < window.end

    :covered
  end

  # NAB / IRIS deposit records dated this day. For each merchant, exactly one
  # snapshot is used: the newest complete one whose window covers the day.
  # Overlapping snapshots are never added together.
  def deposits
    @deposits ||= IrisReport.where(status: 'complete', report_kind: DEPOSIT_KINDS)
      .where('window_from <= ? AND window_to >= ?', date, date).to_a
      .group_by { |report| [report.api_origin, report.merchant_number] }
      .filter_map do |(_origin, merchant), candidates|
        report = candidates.max_by { |candidate| [candidate.observed_at, candidate.id] }
        data = report.payload
        key = report.report_kind == 'deposits' ? 'deposits' : 'data'
        records = Array(data[key]).select { |record| record['date'].to_s == date.iso8601 }
        cents = records.sum { |record| (BigDecimal(record.fetch('amount').to_s) * 100).round.to_i }
        Deposit.new(merchant_label: masked(merchant), report_kind: report.report_kind, observed_at: report.observed_at,
          records: records, amount_cents: records.empty? ? nil : cents, currency: data['currency'],
          partial_window: data['coverage'] == 'export_records_only')
      rescue JSON::ParserError, ArgumentError, KeyError, TypeError
        nil
      end
  end

  def deposits_with_records
    deposits.select { |deposit| deposit.records.any? }
  end

  # Arithmetic difference only (deposit minus card net); used when no funding
  # merchant has been chosen.
  def deposit_difference_cents(deposit)
    return nil if deposit.amount_cents.nil? || card_net_cents.nil?

    deposit.amount_cents - card_net_cents
  end

  # NAB merchants that have deposit snapshots, for the owner's choice.
  def self.deposit_merchants
    IrisReport.where(report_kind: DEPOSIT_KINDS).distinct.pluck(:merchant_number).sort
  end

  def self.mask(merchant)
    "••#{merchant.to_s.last(4)}"
  end

  # Opaque form value, so full merchant numbers never appear in page HTML.
  def self.merchant_token(merchant)
    Digest::SHA256.hexdigest("swipesimple-deposit-merchant:#{merchant}").first(16)
  end

  # The owner-chosen NAB merchant that funds SwipeSimple card sales, or nil.
  def deposit_merchant
    return @deposit_merchant if defined?(@deposit_merchant)

    @deposit_merchant = TenantSettings.swipesimple_deposit_merchant.to_s.strip.presence
  end

  # With a funding merchant chosen: the first deposit dated 1..FUNDING_LAG_DAYS
  # days AFTER this business day, plus every business day that deposit covers.
  # A business day belongs to the first deposit after it, so a deposit is only
  # ever compared once, against the combined card net of its days (e.g. a
  # Monday deposit after Friday, Saturday and Sunday). NAB Daily Deposits
  # carry no batch or processing date, so matching is by deposit date.
  def deposit_match
    return @deposit_match if defined?(@deposit_match)
    return @deposit_match = nil unless deposit_merchant

    funded_on = (date + 1..date + FUNDING_LAG_DAYS).find { |day| merchant_records(day).any? }
    return @deposit_match = nil unless funded_on

    earlier = (funded_on - FUNDING_LAG_DAYS...funded_on).select { |day| merchant_records(day).any? }.max
    days = ((earlier || funded_on - FUNDING_LAG_DAYS)...funded_on).to_a
    nets = days.to_h { |day| [day, day == date ? card_net_cents : self.class.new(day).card_net_cents] }
    # Leading days with no stored card sales (e.g. before the first deposit
    # in the data) add nothing; keep the list to days that matter.
    days = days.drop_while { |day| day != date && nets[day].nil? }
    nets = nets.slice(*days)
    records = merchant_records(funded_on)
    amount = records.sum { |record| (BigDecimal(record.fetch('amount').to_s) * 100).round.to_i }
    card = nets.values.sum(&:to_i)
    @deposit_match = DepositMatch.new(deposit_date: funded_on, records: records, amount_cents: amount,
      currency: merchant_snapshot(funded_on)&.payload&.dig('currency'), business_days: days,
      card_net_by_day: nets, card_net_cents: card, difference_cents: amount - card)
  rescue ArgumentError, KeyError, TypeError, JSON::ParserError
    @deposit_match = nil
  end

  def checks
    @checks ||= begin
      list = []
      case coverage
      when :future
        list << check(:future, :info, 'This business day has not started yet.')
      when :missing
        list << check(:stale, :warn, 'No stored SwipeSimple transaction export was taken on or after this day. Pull a fresh export before closing; missing data does not mean zero sales.')
      when :partial
        list << check(:stale, :warn, "The newest export was taken at #{format_time(latest_transaction_export.exported_at)}, before this day ended. Later transactions may be missing.")
      end
      list << check(:no_rows, :info, 'The stored exports have no transactions on this day.') if rows.empty? && coverage == :covered
      if unknown_tip_rows.any?
        list << check(:unknown_tips, :warn, "#{unknown_tip_rows.size} approved #{'transaction'.pluralize(unknown_tip_rows.size)} have no tip column in the export. Tips stay Unknown; they are not zero.")
      end
      refunds.each do |refund|
        if refund[:earlier_day]
          list << check(:earlier_refund, :warn, "Refund #{refund[:row].source_number} reverses a sale from #{refund[:sale].occurred_at.in_time_zone(ZONE).to_date.strftime('%b %-d, %Y')}. It lowers today's net, not that day's.")
        elsif refund[:sale].nil?
          list << check(:unmatched_refund, :warn, "Refund #{refund[:row].source_number} has no matching sale in the stored exports.")
        end
      end
      if rows.size >= DECLINE_MIN_ATTEMPTS && excluded.size >= (rows.size * DECLINE_SHARE_FLAG)
        list << check(:declines, :warn, "#{excluded.size} of #{rows.size} attempts were declined, voided, errored or canceled. Check the terminal and processor.")
      end
      list.concat(deposit_checks)
      list
    end
  end

  def warnings
    checks.select { |item| item.level == :warn }
  end

  def review
    return @review if defined?(@review)

    @review = SwipesimpleDayReview.find_by(business_date: date)
  end

  def reviewed?
    review.present? && review.reviewed_digest == source_digest
  end

  # Changes whenever the day's transaction evidence, invoice observations or
  # the deposit records shown here change, which invalidates a local review.
  def source_digest
    @source_digest ||= Digest::SHA256.hexdigest(JSON.generate([
      'swipesimple-day-v2', date.iso8601,
      rows.map { |row| [row.identity, row.transaction_type, row.status, row.tender, row.amount_cents, row.tip_cents, row.occurred_at.utc.iso8601] },
      invoices.map { |row| [row.source_number, row.status, row.amount_cents, row.occurred_at.utc.iso8601] },
      deposit_evidence
    ]))
  end

  def deposit_evidence
    return deposits.map { |deposit| [deposit.merchant_label, deposit.report_kind, deposit.records] } unless deposit_merchant

    match = deposit_match
    [self.class.merchant_token(deposit_merchant), match && [match.deposit_date.iso8601, match.records, match.business_days.map(&:iso8601), match.card_net_by_day.values]]
  end

  def to_csv
    CSV.generate do |csv|
      csv << %w[BusinessDate OccurredAt Account Currency Transaction Type Status Tender Amount Tip InTotals Export Row]
      rows.each do |row|
        csv << [date.iso8601, row.occurred_at.in_time_zone(ZONE).iso8601, safe(row.swipesimple_export.merchant_account), row.swipesimple_export.currency,
          safe(row.source_number), row.transaction_type, row.status, row.tender || 'unknown', dollars(row.amount_cents),
          row.tip_cents.nil? ? 'Unknown' : dollars(row.tip_cents), row.status == 'Approved' ? 'yes' : 'no (excluded)',
          row.swipesimple_export_id, row.source_row]
      end
    end
  end

  private

  def deposit_checks
    unless deposit_merchant
      return [] unless deposits_with_records.empty? && card_net_cents

      return [check(:no_deposit, :info, 'No NAB / IRIS deposit record is dated this day. The processor deposit cannot be compared yet.')]
    end

    match = deposit_match
    label = "NAB merchant #{self.class.mask(deposit_merchant)}"
    unless match
      return [] unless card_net_cents

      return [check(:no_deposit, :info, "No deposit from #{label} is stored for the #{FUNDING_LAG_DAYS} days after this day yet. Card sales usually fund 1–3 days later.")]
    end

    list = []
    if match.business_days.size > 1
      days = match.business_days.map { |day| day.strftime('%a %b %-d') }.to_sentence
      list << check(:grouped_deposit, :info, "The #{match.deposit_date.strftime('%a %b %-d')} deposit covers #{match.business_days.size} business days (#{days}); it is compared with their combined card net.")
    end
    unless match.difference_cents.zero?
      list << check(:deposit_difference, :warn, "The #{label} deposit on #{match.deposit_date.strftime('%b %-d')} differs from SwipeSimple card net by #{format('%<sign>s$%<amount>.2f', sign: match.difference_cents.negative? ? '-' : '', amount: match.difference_cents.abs / 100.0)}. Fees, chargebacks or card sales outside SwipeSimple can explain it; note what you find.")
    end
    list
  end

  # Newest complete snapshot of the chosen merchant covering `day`. One
  # snapshot per date: overlapping windows are never added together.
  def merchant_snapshot(day)
    @merchant_reports ||= IrisReport.where(status: 'complete', report_kind: DEPOSIT_KINDS, merchant_number: deposit_merchant)
      .where('window_from <= ? AND window_to >= ?', date + FUNDING_LAG_DAYS, date - FUNDING_LAG_DAYS).to_a
    @merchant_reports.select { |report| report.window_from <= day && report.window_to >= day }
      .max_by { |report| [report.observed_at, report.id] }
  end

  def merchant_records(day)
    @merchant_records ||= {}
    @merchant_records[day] ||= begin
      report = merchant_snapshot(day)
      if report
        data = report.payload
        Array(data[report.report_kind == 'deposits' ? 'deposits' : 'data']).select { |record| record['date'].to_s == day.iso8601 }
      else
        []
      end
    end
  end

  def build_group(account, currency, tender, list)
    ok = list.select { |row| row.status == 'Approved' }
    sales = ok.select { |row| row.transaction_type == 'Sale' }
    refund_rows = ok.select { |row| row.transaction_type == 'Refund' }
    sale_cents = sales.sum(&:amount_cents)
    refund_cents = refund_rows.sum(&:amount_cents)
    Group.new(account: account, currency: currency, tender: tender, sale_count: sales.size, sale_cents: sale_cents,
      refund_count: refund_rows.size, refund_cents: refund_cents, net_cents: sale_cents - refund_cents,
      # Tips are already inside Amount. One sale without tip evidence makes the
      # group's tip total Unknown rather than understated.
      tip_cents: sales.all?(&:tip_cents) ? sales.sum(&:tip_cents) : nil,
      missing_tip_rows: ok.count { |row| row.tip_cents.nil? },
      declined_count: list.count { |row| row.status == 'Declined' }, voided_count: list.count { |row| row.status == 'Voided' },
      other_excluded_count: list.count { |row| %w[Errored Canceled].include?(row.status) })
  end

  # Mirrors SwipesimpleReportImporter's transaction identity for the Sale with
  # the same source transaction number.
  def sale_identity(row)
    export = row.swipesimple_export
    Digest::SHA256.hexdigest(JSON.generate([export.merchant_account, export.currency, 'transactions', row.source_number, 'Sale']))
  end

  def masked(merchant)
    "MID ••#{merchant.to_s.last(4)}"
  end

  def check(key, level, message)
    Check.new(key: key, level: level, message: message)
  end

  def format_time(value)
    value.in_time_zone(ZONE).strftime('%b %-d, %Y · %-I:%M %p %Z')
  end

  def dollars(cents)
    format('%.2f', cents / 100.0)
  end

  def safe(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) ? "'#{text}" : text
  end
end
