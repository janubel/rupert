# frozen_string_literal: true

module SwipesimpleWeb
  class Check
    def self.call(connection:)
      snapshots = Client.new(connection.credential_values, company_id: connection.account_reference).fetch
      snapshots.each do |snapshot|
        SwipesimpleReportImporter.preview(snapshot.text, kind: snapshot.kind,
          merchant_account: snapshot.merchant_account, currency: 'USD', source_timezone: 'America/New_York',
          exported_at: snapshot.exported_at, invoice_scope: 'full')
      end
      { status: 'verified', message: 'SwipeSimple sign-in and both fresh website exports checked. No snapshots were imported.' }
    rescue Client::Error => e
      { status: 'failed', message: e.message }
    rescue SwipesimpleReportImporter::Error
      { status: 'failed', message: Client::Error.new(:response).message }
    end
  end
end
