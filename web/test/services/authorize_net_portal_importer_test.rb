# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetPortalImporterTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'native portal evidence is encrypted replay safe and independent of API and retail sales' do
    assert_no_difference ['AuthorizeNetTransaction.unscoped.count', 'Core::Order.unscoped.count'] do
      assert_difference 'AuthorizeNetPortalExport.count', 1 do
        receipt = import
        assert_equal '2026-10-15T18:20:58Z', receipt.records.first['submitted_at']
        assert_equal 12345, receipt.records.first['settlement_cents']
        assert_equal csv, receipt.original_csv
        raw = receipt.attributes_before_type_cast
        refute_includes raw['original_csv'], 'Transaction ID'
        assert_equal receipt.id, import.id
      end
    end
  end

  test 'late historical imports do not overwrite newer transaction results' do
    import(status: 'Settled Successfully', exported_at: '2026-10-16T00:00:00Z')
    import(status: 'Captured/Pending Settlement', exported_at: '2026-10-15T23:00:00Z')
    assert_equal ['Settled Successfully'], AuthorizeNetPortalExport.latest_records.pluck('status')
  end

  test 'duplicate IDs currencies and invalid source times fail before publishing' do
    assert_no_difference 'AuthorizeNetPortalExport.count' do
      assert_raises(AuthorizeNetPortalImporter::Error) { import(text: csv + csv.lines.last) }
      assert_raises(AuthorizeNetPortalImporter::Error) { import(text: csv.sub('USD,15-Oct', 'CAD,15-Oct')) }
      assert_raises(AuthorizeNetPortalImporter::Error) { import(text: csv.gsub('EDT', 'UNKNOWN')) }
      assert_raises(AuthorizeNetPortalImporter::Error) { import(gateway_id: 'not-an-id') }
    end
  end

  test 'another tenant cannot see portal observations or source files' do
    import
    Current.tenant = Tenant.create!(name: 'Other portal', subdomain: 'other-portal')
    assert_empty AuthorizeNetPortalExport.latest_records
    assert_equal 0, AuthorizeNetPortalExport.count
  end

  private

  def csv(status: 'Settled Successfully')
    CSV.generate do |out|
      out << AuthorizeNetPortalImporter::REQUIRED
      out << ['123456789', status, '123.45', 'USD', '15-Oct-2026 03:20:58 PM EDT',
        '123.45', 'USD', '15-Oct-2026 02:20:58 PM EDT', '0', 'Authorization w/ Auto Capture']
    end
  end

  def import(status: 'Settled Successfully', **options)
    AuthorizeNetPortalImporter.import!(**{ text: csv(status: status), gateway_id: '123456', kind: 'settled',
      exported_at: '2026-10-16T00:00:00Z' }.merge(options))
  end
end
