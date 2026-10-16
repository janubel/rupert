# frozen_string_literal: true

require 'test_helper'

class DirectorySyncJobTest < ActiveJob::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true, hourly_sync_enabled: true,
      credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'private-secret' }.to_json)
  end

  teardown { Current.reset }

  test 'scheduler fans out by tenant source and directory without embedding credentials' do
    assert_enqueued_with(job: DirectorySyncJob, args: [Current.tenant_id, 'ctrax', 'customers']) { DirectorySyncJob.perform_now }
    assert enqueued_jobs.any? { |job| job[:args].last == 'employees' }
    refute_includes enqueued_jobs.inspect, 'private-secret'
    clear_enqueued_jobs
    @connection.update!(hourly_sync_enabled: false)
    assert_no_enqueued_jobs { DirectorySyncJob.perform_now }
  end

  test 'inactive tenants and revoked credentials prevent queued reads' do
    Directories::Sync.expects(:call).never
    @connection.update_columns(vendor_approved: false)
    DirectorySyncJob.perform_now(Current.tenant_id, 'ctrax', 'employees')
    tenants(:default_tenant).update!(status: 'suspended')
    DirectorySyncJob.perform_now(tenants(:default_tenant).id, 'ctrax', 'customers')
  end

  test 'scheduler and queued reads refresh credentials cached before another process removed settings' do
    @connection.update!(hourly_sync_enabled: false)
    keys = %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN]
    keys.each { |key| EnvStore.set(key, 'fixture') }
    assert Directories::Sync.available?('shopify')
    # Another process cannot clear this worker's request-local memoization.
    Setting.where(tenant_id: Current.tenant_id, key: keys).delete_all
    assert_no_enqueued_jobs { DirectorySyncJob.perform_now }
    keys.each { |key| EnvStore.set(key, 'fixture') }
    assert Directories::Sync.available?('shopify')
    Setting.where(tenant_id: Current.tenant_id, key: keys).delete_all
    Directories::Sync.expects(:call).never
    DirectorySyncJob.perform_now(Current.tenant_id, 'shopify', 'customers')
  end
end
