# frozen_string_literal: true

require 'test_helper'

class CtraxStockSyncJobTest < ActiveJob::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true, hourly_sync_enabled: true,
      credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'private-password' }.to_json)
  end

  teardown { Current.reset }

  test 'scheduler enqueues only enabled active workspace connections without credentials' do
    assert_enqueued_with(job: CtraxStockSyncJob, args: [@connection.id]) { CtraxStockSyncJob.perform_now }
    assert_not_includes enqueued_jobs.inspect, 'private-password'
    clear_enqueued_jobs
    @connection.tenant.update!(status: 'suspended')
    assert_no_enqueued_jobs { CtraxStockSyncJob.perform_now }
  end

  test 'worker scopes its tenant and restores previous context' do
    previous = Tenant.create!(name: 'Previous context', subdomain: 'ctrax-job-context')
    Current.tenant = previous
    Ctrax::StockSync.expects(:call).with { |connection:| connection.tenant_id == @connection.tenant_id && Current.tenant_id == @connection.tenant_id }
                    .returns(stores: 1, variants: 2)
    CtraxStockSyncJob.perform_now(@connection.id)
    assert_equal previous.id, Current.tenant_id
  end

  test 'removing credentials or disabling schedule prevents queued work from connecting' do
    Ctrax::StockSync.expects(:call).never
    @connection.update!(hourly_sync_enabled: false)
    CtraxStockSyncJob.perform_now(@connection.id)
    @connection.update!(hourly_sync_enabled: true, credentials_json: '{}')
    CtraxStockSyncJob.perform_now(@connection.id)
  end
end
