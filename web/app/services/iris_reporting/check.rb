# frozen_string_literal: true

module IrisReporting
  class Check
    def self.call(connection:)
      raise Client::Error, :invalid unless connection.tenant_id == Current.tenant_id && connection.provider == 'iris_reporting' && connection.environment == 'production' && connection.vendor_approved && connection.credentials_saved?

      Client.merchants(connection.account_reference).each do |mid|
        client = Client.new(connection.credential_values)
        %w[transactions deposits].each { |kind| Import.sanitize(kind, client.report(kind, merchant: mid, from: Date.current, to: Date.current)) }
      end
      { status: 'verified', message: 'IRIS deposit and batch/transaction read access checked for every configured merchant. No reports were imported.' }
    rescue Client::Error => e
      { status: 'failed', message: e.message }
    end
  end
end
