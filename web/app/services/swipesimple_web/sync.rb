# frozen_string_literal: true

module SwipesimpleWeb
  class Sync
    REPORT_DAYS = 45
    # Older report months are filled in automatically, a few per pull, back to
    # this many months before the rolling window, until every month is stored.
    HISTORY_MONTHS = 36
    HISTORY_MONTHS_PER_PULL = 3
    HISTORY_PAUSE = Rails.env.test? ? 0 : 1

    def self.call(connection:)
      SyncObservability.observe('swipesimple', 'web') { new(connection).call }
    end

    # The calendar months covering at least the last REPORT_DAYS days, so each
    # stored month is replaced whole and ended months are retained once.
    def self.report_window
      today = ReportStore.today
      (today - (REPORT_DAYS - 1)).beginning_of_month..today
    end

    def initialize(connection)
      @connection = connection
    end

    def call
      raise Client::Error, :invalid unless @connection.persisted? && @connection.provider == 'swipesimple' && @connection.tenant_id == Current.tenant_id && @connection.vendor_approved && @connection.credentials_saved?

      # Claim once, without holding a DB transaction during website requests.
      # A crashed process may be retried after ten minutes.
      return { busy: true } if @connection.last_report_status == 'running' && @connection.updated_at > 10.minutes.ago

      version = @connection.lock_version
      claimed = PosConnection.where(id: @connection.id, lock_version: version).update_all(
        last_report_status: 'running', last_report_message: 'Reading fresh SwipeSimple website exports.',
        updated_at: Time.current, lock_version: version + 1)
      return { busy: true } unless claimed == 1

      version += 1
      client = Client.new(@connection.credential_values, company_id: @connection.account_reference)
      snapshots = client.fetch
      transactions = snapshots.select { |snapshot| snapshot.kind == 'transactions' }
      invoices = snapshots.select { |snapshot| snapshot.kind == 'invoices' }
      raise Client::Error, :response unless transactions.any? && invoices.one?

      accounts = transactions.map(&:merchant_account)
      previous_accounts = SwipesimpleExport.distinct.pluck(:merchant_account)
      # A new account (e.g. a second card terminal) joins the known ones; a pull
      # that shares no account with earlier pulls is a different merchant.
      raise Client::Error, :identity if previous_accounts.any? && (previous_accounts & accounts).empty?

      # The invoice export has no account column; it stays with the account that
      # already holds the invoices (else the earliest known, else the largest).
      primary = self.class.primary_account(accounts, transactions)
      invoices.first.merchant_account = primary
      prepared = snapshots.map do |snapshot|
        options = { kind: snapshot.kind, merchant_account: snapshot.merchant_account, currency: 'USD',
          source_timezone: 'America/New_York', exported_at: snapshot.exported_at, invoice_scope: 'full' }
        SwipesimpleReportImporter.preview(snapshot.text, options)
      end

      # Reports and items are read after the transaction exports and fail on
      # their own: a problem there never blocks the transaction pull. With
      # several accounts each report is read per account, so its days match
      # that account's transactions.
      window = self.class.report_window
      ids = isolated { accounts.one? ? { primary => nil } : client.merchant_account_ids(accounts) }
      earliest = prepared.select { |item| item.context['kind'] == 'transactions' }
        .to_h { |item| [item.context['merchant_account'], item.rows.filter_map { |row| row[:occurred_at] }.min] }
      plans = accounts.to_h do |account|
        missing = self.class.missing_history(account, since: earliest[account])
        [account, { missing: missing, reports: nil, history: nil }]
      end
      plans.each do |account, plan|
        if ids.is_a?(Client::Error)
          plan[:reports] = plan[:history] = ids
          next
        end
        id = ids.fetch(account)
        plan[:reports] = isolated { Client::REPORT_TOPICS.flat_map { |topic| client.report(topic, from: window.first, to: window.last, merchant_account_id: id) } }
        plan[:history] = isolated { history_reports(client, plan[:missing].first(HISTORY_MONTHS_PER_PULL), id) }
      end
      items = isolated { client.items_workbook }
      counts = { transactions: 0, invoices: 0 }
      prepared.each { |item| counts[item.context['kind'].to_sym] += item.rows.size }
      @connection.with_lock do
        raise Client::Error, :changed unless @connection.lock_version == version

        prepared.each do |item|
          latest = SwipesimpleExport.where(kind: item.context['kind'], merchant_account: item.context['merchant_account'],
            currency: item.context['currency'], source_timezone: item.context['source_timezone']).order(exported_at: :desc).first
          # A fresh HTTP read can return identical bytes. Keep its verified read
          # time on the connection without storing another identical full copy.
          next if latest&.sha256 == item.sha256

          SwipesimpleReportImporter.import!(item.text, item.context, expected_fingerprint: item.fingerprint)
        end
        notes = []
        report_results = []
        history_results = []
        plans.each do |account, plan|
          label = accounts.one? ? nil : account
          result, note = store_reports(plan[:reports], account)
          report_results << result
          notes << [label, note].compact.join(': ')
          result, note = store_history(plan[:history], account, plan[:missing])
          history_results << result
          notes << [label, note].compact.join(': ') if note
        end
        counts[:reports] = report_results.uniq.one? ? report_results.first : :partial
        counts[:report_history] = history_results.uniq.one? ? history_results.first : :partial
        counts[:items], items_note = store_items(items, primary)
        accounts_note = accounts.one? ? '' : " across #{accounts.size} merchant accounts"
        @connection.update!(last_report_status: 'succeeded',
          last_report_message: "Website pull completed: #{counts[:transactions]} transactions#{accounts_note}, #{counts[:invoices]} invoices. #{(notes + [items_note]).join(' ')}",
          last_reported_at: snapshots.map { |snapshot| Time.iso8601(snapshot.exported_at) }.min,
          last_check_status: 'verified', last_checked_at: Time.current, last_check_message: 'SwipeSimple website read access verified.')
      end
      counts
    rescue SwipesimpleReportImporter::Error, ActiveRecord::ActiveRecordError
      fail_pull(version, Client::Error.new(:response))
    rescue Client::Error => e
      fail_pull(version, e)
    end

    # Ended months before the rolling window that lack a whole-month pull for
    # either topic, newest first. Never before the account's first transaction
    # (since:) or HISTORY_MONTHS before the window.
    def self.missing_history(account, since: nil)
      window = report_window
      last = window.first - 1
      first = (window.first << HISTORY_MONTHS).beginning_of_month
      first = [first, since.to_date.beginning_of_month].max if since
      return [] if first > last

      covered = SwipesimpleReportPull.where(merchant_account: account, period_from: first..last)
        .pluck(:topic, :period_from, :period_to)
        .select { |_topic, from, to| from == from.beginning_of_month && to == from.end_of_month }
        .group_by { |_topic, from, _to| from }
        .select { |_from, pulls| pulls.map(&:first).uniq.size == Client::REPORT_TOPICS.size }.keys
      Client.months(first, last).map(&:first).reject { |month| covered.include?(month) }.reverse
    end

    # The account the company-wide invoice export and item list are filed under.
    def self.primary_account(accounts, transactions)
      invoice_account = SwipesimpleExport.where(kind: 'invoices', merchant_account: accounts).order(exported_at: :desc).pick(:merchant_account)
      return invoice_account if invoice_account

      known = SwipesimpleExport.where(merchant_account: accounts).order(:exported_at).pick(:merchant_account)
      return known if known

      sizes = transactions.to_h { |snapshot| [snapshot.merchant_account, snapshot.text.count("\n")] }
      accounts.max_by { |account| [sizes[account], account] }
    end

    private

    def isolated
      yield
    rescue Client::Error => e
      e
    end

    def store_reports(result, account)
      return [:failed, "Tax and sales reports were not updated: #{result.message}"] if result.is_a?(Client::Error)

      ActiveRecord::Base.transaction(requires_new: true) { result.each { |chunk| ReportStore.replace!(chunk, merchant_account: account) } }
      [:pulled, "Tax and sales reports pulled for #{result.map(&:from).min} through #{result.map(&:to).max}."]
    rescue ActiveRecord::ActiveRecordError, ReconciliationEvidence::Error
      [:failed, 'Tax and sales reports could not be stored; the previous report days were retained.']
    end

    def history_reports(client, months, merchant_account_id = nil)
      months.each_with_index.flat_map do |month, index|
        sleep(HISTORY_PAUSE) if index.positive? && HISTORY_PAUSE.positive?
        Client::REPORT_TOPICS.flat_map { |topic| client.report(topic, from: month, to: month.end_of_month, merchant_account_id: merchant_account_id) }
      end
    end

    def store_history(result, account, missing)
      return [:complete, nil] if missing.empty?
      return [:failed, "Older report months were not filled: #{result.message}"] if result.is_a?(Client::Error)

      ActiveRecord::Base.transaction(requires_new: true) { result.each { |chunk| ReportStore.replace!(chunk, merchant_account: account) } }
      filled = result.map(&:from).uniq.sort
      left = missing.size - filled.size
      [:filled, "Older report months filled: #{filled.map { |d| d.strftime('%Y-%m') }.join(', ')}" \
        "#{left.positive? ? " (#{left} more to fetch on later pulls)." : ' (history complete).'}"]
    rescue ActiveRecord::ActiveRecordError, ReconciliationEvidence::Error
      [:failed, 'Older report months could not be stored; they will be retried on the next pull.']
    end

    def store_items(result, account)
      return [:failed, "Items were not updated: #{result.message}"] if result.is_a?(Client::Error)

      changed = ActiveRecord::Base.transaction(requires_new: true) { ReportStore.replace_items!(result, merchant_account: account) }
      changed ? [:updated, "#{result.records.size} active items pulled."] : [:unchanged, 'Item list unchanged.']
    rescue ActiveRecord::ActiveRecordError
      [:failed, 'Items could not be stored; the previous item list was retained.']
    end

    def fail_pull(version, error)
      if version
        updates = { last_report_status: error.login_required? ? 'needs_login' : 'failed',
          last_report_message: error.message, updated_at: Time.current, lock_version: version + 1 }
        updates[:reporting_enabled] = false if error.login_required?
        PosConnection.where(id: @connection.id, lock_version: version).update_all(updates)
      end
      raise error, cause: nil
    end
  end
end
