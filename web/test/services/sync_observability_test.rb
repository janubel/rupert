# frozen_string_literal: true

require 'test_helper'

class SyncObservabilityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { Current.user = users(:regular_user) }
  teardown { Current.reset }

  test 'safe receipt preserves result and stores no exception text or credential copy' do
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'synthetic-secret-do-not-log')
    before = Setting.find_by!(key: 'SQUARE_ACCESS_TOKEN').attributes_before_type_cast
    error = RuntimeError.new('synthetic-secret-do-not-log private vendor response')
    assert_same error, assert_raises(RuntimeError) { SyncObservability.observe('square', 'catalog') { raise error } }
    row = SyncAttempt.last
    assert_equal 'failed', row.status
    assert_equal 'unknown', row.error_category
    refute_includes row.attributes.to_json, 'synthetic-secret'
    assert_equal before, Setting.find_by!(key: 'SQUARE_ACCESS_TOKEN').attributes_before_type_cast
    value = { count: 0 }
    assert_same value, SyncObservability.observe('square', 'catalog') { value }
    assert_equal 'succeeded', SyncAttempt.last.status
  end

  test 'typed reasons distinguish permission login verification malformed data and limits' do
    { login: 'credentials', verification: 'verification', response: 'data_contract', identity: 'identity',
      limit: 'read_limit', changed: 'setup_changed', network: 'network' }.each do |reason, category|
      assert_equal category, SyncFailure.category(SwipesimpleWeb::Client::Error.new(reason))
    end
    assert_equal 'entitlement', SyncFailure.category(Ctrax::Client::Error.new(:forbidden))
    assert_equal 'rate_limit', SyncFailure.category(IrisReporting::Client::Error.new(:rate_limit))
    assert_equal 'credentials', SyncFailure.category(AuthorizeNetReporting::Client::Error.new('not persisted', reason: :unauthorized))
    assert_equal 'encryption', SyncFailure.category(ActiveRecord::Encryption::Errors::Decryption.new)
    assert_equal 'timeout', SyncFailure.category(Timeout::Error.new)
    assert_equal 'storage', SyncFailure.category(ActiveRecord::StatementInvalid.new)
  end

  test 'metadata database failure never changes connector outcome or exception' do
    SyncAttempt.stubs(:where).raises(ActiveRecord::StatementInvalid.new('private database error'))
    Current.metadata[:sync_job_id] = 'synthetic-job'
    assert_equal :original, SyncObservability.observe('square', 'catalog') { :original }
    error = RuntimeError.new('original')
    assert_same error, assert_raises(RuntimeError) { SyncObservability.observe('square', 'catalog') { raise error } }
  end

  test 'busy concurrent read does not create a successful acquisition' do
    assert_equal({ busy: true }, SyncObservability.observe('swipesimple', 'web') { { busy: true } })
    assert_equal 'skipped', SyncAttempt.last.status
    assert_nil SyncAttempt.where(status: 'succeeded').first
  end

  test 'enqueue perform and retry receipts are bound to the intended tenant and job' do
    job = SyncJob.perform_later(tenant_id: Current.tenant_id, source: 'shopify')
    queued = SyncAttempt.find_by!(active_job_id: job.job_id)
    assert_equal 'queued', queued.status
    assert_nil queued.started_at
    SyncObservability.perform(job) { SyncObservability.observe('shopify', 'catalog') { :ok } }
    assert_equal 'succeeded', queued.reload.status
    assert_not_nil queued.started_at
    assert_not_nil queued.finished_at
    SyncObservability.queued(job)
    SyncObservability.perform(job) do
      assert_raises(RuntimeError) { SyncObservability.observe('shopify', 'catalog') { raise 'synthetic' } }
    end
    assert_equal %w[succeeded failed], SyncAttempt.where(active_job_id: job.job_id).order(:id).pluck(:status)
    assert_nil Current.metadata[:sync_job_id]
  end

  test 'skipped or aborted jobs do not leave phantom queued attempts' do
    job = SyncJob.perform_later(tenant_id: Current.tenant_id, source: 'square')
    SyncObservability.perform(job) { nil }
    assert_equal 'skipped', SyncAttempt.find_by!(active_job_id: job.job_id).status
    job = SyncJob.perform_later(tenant_id: Current.tenant_id, source: 'square')
    assert_raises(RuntimeError) { SyncObservability.perform(job) { raise 'worker failed before reading' } }
    row = SyncAttempt.find_by!(active_job_id: job.job_id)
    assert_equal 'failed', row.status
    assert_equal 'worker', row.error_category
  end

  test 'platform backup receipts cannot become workspace records' do
    job = BackupJob.perform_later
    row = SyncAttempt.unscoped.find_by!(active_job_id: job.job_id)
    assert_nil row.tenant_id
    assert_empty SyncAttempt.where(source: 'google_backup')
  end

  test 'diagnostic failure does not alter encrypted provider credentials setup version or schedule flags' do
    connection = PosConnection.create!(provider: 'swipesimple', environment: 'production', account_reference: '42',
      vendor_approved: true, reporting_enabled: true,
      credentials_json: { web_email: 'synthetic@example.com', web_password: 'synthetic-private-password' }.to_json)
    before = connection.reload.attributes_before_type_cast
    assert_raises(RuntimeError) { SyncObservability.observe('swipesimple', 'web') { raise 'synthetic-failure' } }
    assert_equal before, connection.reload.attributes_before_type_cast
  end
end
