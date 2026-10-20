# frozen_string_literal: true

require 'test_helper'

class SyncJobTest < ActiveJob::TestCase
  setup { @tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'a transient failure re-enqueues the job with backoff instead of giving up' do
    SyncEngine.stubs(:run!).raises(ShopifyClient::Error.new('GraphQL failed (HTTP 503).', reason: :vendor))
    assert_enqueued_with(job: SyncJob) do
      SyncJob.perform_now(tenant_id: @tenant.id, mode: 'scheduled')
    end
    assert_no_enqueued_jobs(only: BuzzNotifyJob)
  end

  test 'a credential failure is not retried and raises an alert' do
    SyncEngine.stubs(:run!).raises(ShopifyClient::Error.new('Token exchange failed (HTTP 401).', reason: :unauthorized))
    assert_raises(ShopifyClient::Error) { SyncJob.perform_now(tenant_id: @tenant.id, mode: 'scheduled') }
    assert_no_enqueued_jobs(only: SyncJob)
    assert_enqueued_with(job: BuzzNotifyJob)
  end

  test 'the alert fires once when transient retries are exhausted' do
    SyncEngine.stubs(:run!).raises(Net::ReadTimeout.new('slow'))
    job = SyncJob.new(tenant_id: @tenant.id, mode: 'scheduled')
    # retry_on counts attempts per exception class; this is the 4th TransientFailure.
    job.exception_executions = { '[SyncJob::TransientFailure]' => 3 }
    assert_raises(SyncJob::TransientFailure) { job.perform_now }
    assert_enqueued_with(job: BuzzNotifyJob)
    assert_no_enqueued_jobs(only: SyncJob)
  end
end
