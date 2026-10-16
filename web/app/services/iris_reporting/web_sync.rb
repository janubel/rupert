# frozen_string_literal: true

module IrisReporting
  class WebSync
    def self.call(connection:)
      SyncObservability.observe('bank', 'web') { new(connection).call }
    end

    def initialize(connection)
      @connection = connection
    end

    def call
      raise WebClient::Error, :invalid unless @connection.persisted? && @connection.provider == 'iris_reporting' &&
        @connection.reporting_auth_mode == 'web' && @connection.environment == 'production' && @connection.tenant_id == Current.tenant_id &&
        @connection.vendor_approved && @connection.credentials_saved?
      return { busy: true } if @connection.last_report_status == 'running' && @connection.updated_at > 10.minutes.ago

      version = @connection.lock_version
      claimed = PosConnection.where(id: @connection.id, lock_version: version).update_all(last_report_status: 'running',
        last_report_message: 'Reading fresh NAB Daily Deposits exports.', updated_at: Time.current, lock_version: version + 1)
      return { busy: true } unless claimed == 1

      version += 1
      month = Time.use_zone('America/New_York') { Date.current.beginning_of_month }
      snapshots = WebClient.new(@connection.credential_values).fetch(merchants: Client.merchants(@connection.account_reference), months: [month.prev_month, month])
      @connection.with_lock do
        raise WebClient::Error, :changed unless @connection.lock_version == version

        snapshots.each do |snapshot|
          report = DailyDepositsCsvImport.call(text: snapshot.text, merchant: snapshot.merchant, period: snapshot.period, origin: WebClient::ORIGIN)
          raise WebClient::Error, :response unless report.payload.fetch('data').sort_by(&:to_json) == snapshot.rows.sort_by(&:to_json)
        end
        @connection.update!(last_report_status: 'complete', last_report_message: "Saved #{snapshots.size} verified native Daily Deposits snapshots.",
          last_reported_at: Time.current, last_check_status: 'verified', last_checked_at: Time.current, last_check_message: 'NAB website merchant identity and native deposit exports verified.')
      end
      { snapshots: snapshots.size }
    rescue Client::Error, ActiveRecord::ActiveRecordError
      fail_pull(version, WebClient::Error.new(:response))
    rescue WebClient::Error => e
      fail_pull(version, e)
    end

    private

    def fail_pull(version, error)
      if version
        updates = { last_report_status: error.login_required? ? 'needs_login' : 'failed', last_report_message: error.message,
          updated_at: Time.current, lock_version: version + 1 }
        updates[:reporting_enabled] = false if error.login_required?
        PosConnection.where(id: @connection.id, lock_version: version).update_all(updates)
      end
      raise error, cause: nil
    end
  end
end
