# frozen_string_literal: true

module SwipesimpleWeb
  class Sync
    def self.call(connection:)
      SyncObservability.observe('swipesimple', 'web') { new(connection).call }
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
      snapshots = Client.new(@connection.credential_values, company_id: @connection.account_reference).fetch
      prepared = snapshots.map do |snapshot|
        options = { kind: snapshot.kind, merchant_account: snapshot.merchant_account, currency: 'USD',
          source_timezone: 'America/New_York', exported_at: snapshot.exported_at, invoice_scope: 'full' }
        SwipesimpleReportImporter.preview(snapshot.text, options)
      end
      raise Client::Error, :response unless prepared.map { |item| item.context['kind'] }.sort == %w[invoices transactions]

      counts = prepared.to_h { |item| [item.context['kind'].to_sym, item.rows.size] }
      @connection.with_lock do
        raise Client::Error, :changed unless @connection.lock_version == version

        previous_accounts = SwipesimpleExport.distinct.pluck(:merchant_account)
        raise Client::Error, :identity if previous_accounts.any? && previous_accounts != [prepared.first.context['merchant_account']]

        prepared.each do |item|
          latest = SwipesimpleExport.where(kind: item.context['kind'], merchant_account: item.context['merchant_account'],
            currency: item.context['currency'], source_timezone: item.context['source_timezone']).order(exported_at: :desc).first
          # A fresh HTTP read can return identical bytes. Keep its verified read
          # time on the connection without storing another identical full copy.
          next if latest&.sha256 == item.sha256

          SwipesimpleReportImporter.import!(item.text, item.context, expected_fingerprint: item.fingerprint)
        end
        @connection.update!(last_report_status: 'succeeded', last_report_message: "Website pull completed: #{counts[:transactions]} transactions, #{counts[:invoices]} invoices.",
          last_reported_at: snapshots.map { |snapshot| Time.iso8601(snapshot.exported_at) }.min,
          last_check_status: 'verified', last_checked_at: Time.current, last_check_message: 'SwipeSimple website read access verified.')
      end
      counts
    rescue SwipesimpleReportImporter::Error, ActiveRecord::ActiveRecordError
      fail_pull(version, Client::Error.new(:response))
    rescue Client::Error => e
      fail_pull(version, e)
    end

    private

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
