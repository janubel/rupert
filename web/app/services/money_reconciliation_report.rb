# frozen_string_literal: true

require 'csv'
require 'bigdecimal'

# Evidence review, not a posting engine. Source totals are never added across
# order, gateway and deposit layers. Missing currency and coverage stay unknown.
class MoneyReconciliationReport
  ZONE = 'America/New_York'
  KINDS = %w[daily weekly monthly quarterly yearly].freeze
  attr_reader :kind, :from, :to

  def self.previous_period(kind, today: Time.find_zone!(ZONE).today)
    case kind
    when 'daily' then today - 1
    when 'weekly' then today.beginning_of_week - 7
    when 'monthly' then today.beginning_of_month - 1
    when 'quarterly' then today.beginning_of_quarter - 1
    when 'yearly' then today.beginning_of_year - 1
    else raise ArgumentError, 'Choose daily, weekly, monthly, quarterly or yearly.'
    end
  end

  def initialize(kind: 'daily', date: Time.find_zone!(ZONE).today)
    raise ArgumentError, 'Choose daily, weekly, monthly, quarterly or yearly.' unless KINDS.include?(kind)

    day = date.is_a?(Date) ? date : Date.iso8601(date.to_s)
    raise ArgumentError, 'Choose a date between 2000 and 2099.' unless day.year.between?(2000, 2099)

    @kind = kind
    @from, @to = case kind
    when 'weekly' then [day.beginning_of_week, day.end_of_week]
    when 'monthly' then [day.beginning_of_month, day.end_of_month]
    when 'quarterly' then [day.beginning_of_quarter, day.end_of_quarter]
    when 'yearly' then [day.beginning_of_year, day.end_of_year]
    else [day, day]
    end
    zone = Time.find_zone!(ZONE)
    @range = zone.local(from.year, from.month, from.day)...zone.local((to + 1).year, (to + 1).month, (to + 1).day)
  end

  def payload
    @payload ||= begin
      @rows = []
      @warnings = [
        'Orders, gateway payments and processor deposits are separate evidence layers; do not add their totals together.',
        'Payment-to-order and payout-to-bank links are not yet established. This report requires review and does not certify a bank reconciliation.',
        'Gateway totals use settlement dates; order totals use sale dates. Fees and funding delays require source evidence.'
      ]
      shopify
      square
      ctrax
      swipesimple
      authorize_net
      iris
      { 'kind' => kind, 'from' => from.iso8601, 'to' => to.iso8601, 'timezone' => ZONE,
        'generated_at' => Time.current.utc.iso8601(6), 'status' => 'Review required',
        'rows' => @rows, 'warnings' => @warnings.uniq,
        'source_coverage' => Finance::SourceCoverage.new(from: from, to: to).rows,
        'sources' => SourceSyncStatus.all.map { |s| s.except(:ready).merge(last_at: s[:last_at]&.utc&.iso8601(6)) } }.deep_stringify_keys
    end
  end

  def save!
    raise ArgumentError, 'An active workspace is required.' unless Current.tenant&.status == 'active'

    MoneyReconciliation.transaction do
      locked = Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      raise ArgumentError, 'An active workspace is required.' unless locked == 1
      report = MoneyReconciliation.find_or_initialize_by(period_kind: kind, period_from: from)
      report.update!(period_to: to, generated_at: Time.current, payload_json: payload.to_json)
      snapshot = payload.except('generated_at').to_json
      evidence_context = { 'period_kind' => kind, 'report_digest' => Digest::SHA256.hexdigest(snapshot) }
      ReconciliationEvidence.retain!(bytes: csv, filename: "money-reconciliation-#{kind}-#{from}.csv", source: 'rupert', kind: 'period_archive',
        from: from.iso8601, to: to.iso8601, metadata: evidence_context, actor: Current.user)
      ReconciliationEvidence.retain!(bytes: snapshot, filename: "money-reconciliation-#{kind}-#{from}.json", source: 'rupert', kind: 'period_archive',
        from: from.iso8601, to: to.iso8601, metadata: evidence_context, actor: Current.user)
      report
    end
  end

  def csv(document = payload)
    CSV.generate do |out|
      out << ['Period', 'From', 'To', 'Source', 'Account', 'Currency', 'Metric', 'Records', 'Amount', 'Evidence']
      document.fetch('rows').each do |row|
        cells = [kind, from.iso8601, to.iso8601, row['source'], row['account'], row['currency'] || 'Unknown', row['metric'], row['count'], row['amount'], row['basis']]
        out << cells.map { |value| value.is_a?(String) && value.match?(/\A[=+@\t\r-]/) && !value.match?(/\A-\d+(?:\.\d+)?\z/) ? "'#{value}" : value }
      end
      document.fetch('warnings').each { |warning| out << [kind, from.iso8601, to.iso8601, 'Review', nil, nil, warning] }
      if document['source_coverage']
        out << ['Source coverage', 'Evidence type', 'Records in selected period', 'Stored records', 'Earliest stored date', 'Latest stored date', 'Last source read']
        document['source_coverage'].each do |source|
          out << source.values_at('label', 'unit', 'period_records', 'stored_records', 'first_date', 'last_date', 'last_read')
        end
        out << ['Stored date ranges do not prove complete history. Missing evidence is not zero activity.']
      end
    end
  end

  private

  def add(source, account, currency, metric, amount, count, basis)
    @rows << { 'source' => source, 'account' => account, 'currency' => currency,
      'metric' => metric, 'amount' => BigDecimal(amount.to_s).to_s('F'), 'count' => count, 'basis' => basis }
  end

  def shopify
    orders = Core::Order.where(source: 'shopify', status: %w[paid fulfilled refunded], occurred_at: @range)
    orders.group(:currency).count.each do |currency, count|
      scoped = orders.where(currency: currency)
      if scoped.where(gross_cents: nil).exists?
        @warnings << 'Shopify recorded sales include missing amounts; no sales total is inferred.'
        next
      end
      gross = scoped.sum(:gross_cents)
      add('Shopify', 'Online orders', currency, 'Recorded sales', BigDecimal(gross.to_s) / 100, count, 'Sale date; includes tax and recorded shipping')
    end
    refunds = Core::Refund.joins(:order).where(orders: { tenant_id: Current.tenant_id, source: 'shopify' }, refunded_at: @range)
    refunds.group('orders.currency').count.each do |currency, count|
      add('Shopify', 'Online orders', currency, 'Recorded refunds', BigDecimal(refunds.where(orders: { currency: currency }).sum(:amount_cents).to_s) / 100, count, 'Refund date; local recorded evidence')
    end
    @warnings << 'No Shopify sales are stored for this period; confirm source coverage before treating that as zero activity.' unless orders.exists?
  end

  def swipesimple
    rows = SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' }, occurred_at: @range).includes(:swipesimple_export).to_a
    rows.group_by { |r| [r.swipesimple_export.merchant_account, r.swipesimple_export.currency, r.tender] }.each do |(account, currency, tender), group|
      %w[Sale Refund].each do |type|
        approved = group.select { |r| r.status == 'Approved' && r.transaction_type == type }
        next if approved.empty?

        add('SwipeSimple', account, currency, "Approved #{type.downcase} · #{tender}", BigDecimal(approved.sum(&:amount_cents).to_s) / 100, approved.size, 'Transaction date; processed amount includes any tip')
      end
    end
    @warnings << 'SwipeSimple invoices are not added to transaction receipts; paid invoice and payment evidence can overlap.'
    @warnings << 'SwipeSimple exports do not establish complete coverage for this period.' if rows.empty?
  end

  def square
    orders = Core::Order.where(source: 'square', status: %w[paid fulfilled refunded], occurred_at: @range)
    orders.group(:currency, :location_id).count.each do |(currency, location_id), count|
      scoped = orders.where(currency: currency, location_id: location_id)
      if scoped.where(gross_cents: nil).exists?
        @warnings << 'Square recorded sales include missing amounts; no sales total is inferred for that location and currency.'
        next
      end
      account = square_location_label(location_id)
      add('Square', account, currency, 'Recorded sales', BigDecimal(scoped.sum(:gross_cents).to_s) / 100, count,
        'Sale date; recorded order total including tax; compare payments separately')
    end
    refunds = Core::Refund.joins(:order).where(orders: { tenant_id: Current.tenant_id, source: 'square' }, refunded_at: @range)
    refunds.group('orders.currency', 'orders.location_id').count.each do |(currency, location_id), count|
      scoped = refunds.where(orders: { currency: currency, location_id: location_id })
      if scoped.where(amount_cents: nil).exists?
        @warnings << 'Square recorded refunds include missing amounts; no refund total is inferred for that location and currency.'
        next
      end
      account = square_location_label(location_id)
      add('Square', account, currency, 'Recorded refunds', BigDecimal(scoped.sum(:amount_cents).to_s) / 100, count,
        'Refund date; local recorded evidence')
    end
    @warnings << 'No Square sales are stored for this period; confirm source coverage before treating that as zero activity.' unless orders.exists?
  end

  def square_location_label(location_id)
    return 'Unassigned location' if location_id.blank?

    locations = Location.where(source: 'square')
    location = locations.find_by(externalId: location_id) || locations.find_by(id: location_id)
    location ? "#{location.name} (#{location.externalId})" : "Location #{location_id}"
  end

  def ctrax
    snapshots = CtraxDay.where(business_date: from..to).to_a
    snapshots.group_by { |day| [day.api_origin, day.store_id, day.currency, day.timezone] }.each do |(_origin, store, currency, timezone), days|
      checks = days.map { |day| Ctrax::Reconciliation.new(day) }
      identities = checks.flat_map { |check| check.orders.map { |row| row['id'] } }
      if identities.uniq.size != identities.size
        @warnings << 'C-Trax source order IDs repeat across stored dates; no period total is inferred. Review the original day snapshots.'
        next
      end
      metrics = {
        'Recorded order total' => checks.map { |check| check.sum(check.orders, 'total') },
        'Recorded tax' => checks.map { |check| check.sum(check.orders, 'tax') },
        'Recorded tips' => checks.map { |check| check.sum(check.orders, 'tip') },
        'Cash receipts' => checks.map { |check| check.sum(check.payments.select { |row| row['type'] == 'cash' }, 'amount') },
        'Card receipts' => checks.map { |check| check.sum(check.payments.select { |row| %w[credit standaloneCardTerminal].include?(row['type']) }, 'amount') },
        'Source refund total' => days.map { |day| day.controls['refunds_totals_sum'] }
      }
      metrics.each do |metric, values|
        if values.any?(&:nil?)
          @warnings << "C-Trax #{metric.downcase} has missing source amounts; no total is inferred."
          next
        end
        count = metric == 'Source refund total' ? nil : checks.sum { |check| check.orders.size }
        add('C-Trax', store, currency, metric, BigDecimal(values.sum.to_s) / 100, count,
          "Native store-day snapshots in #{timezone}; #{days.size} stored date(s); coverage and bank receipt require review")
      end
      @warnings << 'C-Trax native controls or source review remain unresolved.' unless checks.all?(&:matched?) && days.all?(&:reviewed?)
      @warnings << 'C-Trax stored dates cover only part of this period; absent dates are not zero-sales days.' if days.map(&:business_date).uniq.size < (to - from).to_i + 1
    end
    @warnings << 'No C-Trax retail day snapshot is stored for this period; current stock does not establish historical sales.' if snapshots.empty?
  end

  def authorize_net
    # Only transactions with some settlement in range can end in range; their
    # full API and portal history still decides the newest observation.
    api = AuthorizeNetTransaction.where(environment: 'production')
    keys = (AuthorizeNetPortalObservation.where(settled_at: @range).distinct.pluck(:gateway_id, :transaction_id) +
      api.where(settled_at: @range).distinct.pluck(:gateway_id, :source_transaction_id)).to_set
    observations = AuthorizeNetPortalObservation.latest_for(keys).to_h { |r| [[r['gateway_id'], r['transaction_id']], r] }
    api_rows = keys.map(&:last).uniq.each_slice(AuthorizeNetPortalObservation::SLICE).flat_map { |ids| api.where(source_transaction_id: ids).to_a }
    api_rows.select { |r| keys.include?([r.gateway_id, r.source_transaction_id]) }.sort_by(&:id).each do |r|
      previous = observations[[r.gateway_id, r.source_transaction_id]]
      next if previous && Time.iso8601(previous.fetch('exported_at')) > r.observed_at

      observations[[r.gateway_id, r.source_transaction_id]] = {
        'gateway_id' => r.gateway_id, 'status' => r.payment_status, 'transaction_type' => r.transaction_type,
        'settled_at' => r.settled_at&.iso8601, 'submitted_at' => r.submitted_at.iso8601,
        'currency' => r.currency, 'settlement_amount' => r.settled_amount.to_s('F')
      }
    end
    selected = observations.values.select { |r| r['settled_at'].present? && @range.cover?(Time.iso8601(r['settled_at'])) }
    selected.group_by { |r| [r['gateway_id'], r['currency']] }.each do |(account, currency), group|
      sales = group.select { |r| ['Settled Successfully', 'settledSuccessfully'].include?(r['status']) && !r['transaction_type'].to_s.downcase.include?('refund') }
      refunds = group.select { |r| ['Refund Settled Successfully', 'Refund', 'refundSettledSuccessfully'].include?(r['status']) || (['Settled Successfully', 'settledSuccessfully'].include?(r['status']) && r['transaction_type'].to_s.downcase.include?('refund')) }
      [['Settled sales', sales], ['Settled refunds', refunds]].each do |metric, values|
        next if values.empty?

        add('Authorize.net', account, currency, metric, values.sum(BigDecimal('0')) { |r| r['settlement_amount'] ? BigDecimal(r['settlement_amount']) : BigDecimal(r.fetch('settlement_cents').to_s) / 100 }, values.size, 'Settlement date; newest API/portal observation per transaction')
      end
    end
    @warnings << 'Authorize.net portal snapshots may cover only a selected range; missing rows do not prove zero settlements.'
  end

  def iris
    reports = IrisReport.where('window_from <= ? AND window_to >= ?', to, from).where(status: 'complete').to_a
    deposit_count = 0
    reports.select { |r| %w[deposits daily_deposits_csv].include?(r.report_kind) }.group_by { |r| [r.api_origin, r.merchant_number] }.each do |(_origin, merchant), candidates|
      month = from.beginning_of_month
      while month <= to
        left = [from, month].max
        right = [to, month.end_of_month].min
        overlaps = candidates.select { |r| r.window_from <= right && r.window_to >= left }
        covering = overlaps.select { |r| r.window_from <= left && r.window_to >= right }
        report = (covering.presence || overlaps).max_by { |r| [r.observed_at, r.id] }
        if report
          data = report.payload
          records = data.fetch(report.report_kind == 'deposits' ? 'deposits' : 'data').select { |r| (left..right).cover?(Date.iso8601(r.fetch('date'))) }
          add('NAB / IRIS', merchant, data['currency'], 'Reported deposits / batches', records.sum(BigDecimal('0')) { |r| BigDecimal(r.fetch('amount').to_s) }, records.size, 'Processor date; one newest covering snapshot per merchant/month; bank receipt unverified')
          deposit_count += 1
          @warnings << 'Native NAB deposit exports establish exported-row coverage only; the selected report window is not proof of complete bank activity.' if data['coverage'] == 'export_records_only'
          @warnings << 'A selected NAB deposit snapshot covers only part of this reporting window.' if covering.empty?
          @warnings << 'NAB deposit currency and net ACH funding are unconfirmed; do not compare this amount to USD sales or bank cash.' unless data['currency']
          adjustments = data.fetch('adjustments', []).select { |r| (left..right).cover?(Date.iso8601(r.fetch('date'))) }
          if adjustments.any?
            add('NAB / IRIS', merchant, data['currency'], 'Processor adjustments', adjustments.sum(BigDecimal('0')) { |r| BigDecimal(r.fetch('amount').to_s) }, adjustments.size, 'Separate signed adjustments; not merged into deposits')
          end
        end
        month = month.next_month
      end
    end
    reports.select { |r| r.report_kind == 'sales_health_csv' && r.window_from >= from && r.window_to <= to }.each do |report|
      report.payload.fetch('data').each do |row|
        add('NAB / IRIS', report.merchant_number, nil, "Monthly summary · #{row.fetch('metric').tr('_', ' ')}", row.fetch('value'), nil, 'Whole source month only; separate from deposit totals; currency unconfirmed')
      end
    end
    @warnings << 'No native Daily Deposits or API deposit snapshot covers this period. Import the matching NAB export to review deposits.' if deposit_count.zero?
    @warnings << 'Monthly NAB summaries cannot establish daily/weekly deposits or actual bank statement receipt.'
    @warnings << 'C-Trax stock snapshots are separate from its native daily retail reports; stock does not establish sales.'
  end
end
