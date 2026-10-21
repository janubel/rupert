# frozen_string_literal: true

require 'test_helper'

class SystemPageTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.tenant = nil }

  test 'super admin can view system health' do
    users(:regular_user).update!(role: 'super_admin')
    get system_path
    assert_response :success
    assert_select 'h1', /System health/
    assert_select 'p', /Load average|Memory|Swap|Disk/
    assert_select 'h2', %r{Web server|Background jobs|Database}
  end

  test 'recent errors card is empty and calm when nothing went wrong' do
    users(:regular_user).update!(role: 'super_admin')
    OpsEvent.delete_all
    get system_path
    assert_select '#ops-activity h2', 'Recent errors and activity'
    assert_select '#ops-activity', /All quiet/
    assert_select '#ops-activity', /Nothing has gone wrong/
  end

  test 'recent errors card shows counts and one redacted line per problem, never raw log text' do
    users(:regular_user).update!(role: 'super_admin')
    OpsEvent.delete_all
    3.times { OpsLog.event('request', level: :error, method: 'POST', route: '/orders', status: 500, controller: 'orders', action: 'create', request_id: 'abc12345-0000', error_class: 'ActiveRecord::StatementInvalid') }
    OpsLog.event('validation_failed', level: :warn, model: 'Core::Customer', fields: %w[crm_status], kinds: %w[inclusion], controller: 'customers', action: 'create')
    OpsLog.event('job', level: :error, job_class: 'BackupJob', queue: 'default', error_class: 'Errno::ENOSPC', outcome: 'failed')
    get system_path
    assert_response :success
    assert_select '#ops-activity', /Needs attention/
    assert_select '#ops-activity dl div', /Server errors\s*3/
    assert_select '#ops-activity dl div', /Rejected forms\s*1/
    assert_select '#ops-activity dl div', /Job failures\s*1/
    assert_select '#ops-activity li', /POST \/orders 500 \(orders#create\) ActiveRecord::StatementInvalid/
    assert_select '#ops-activity li', /×3/
    assert_select '#ops-activity li', /BackupJob on default/
    assert_select '#ops-activity li', /abc12345/
    assert_no_match(/"ts":|"level":/, response.body)
  end

  test 'recent errors card is for platform administrators only' do
    users(:regular_user).update!(role: 'admin')
    get system_path
    assert_redirected_to root_path
  end

  test 'AI health card shows the expired-key warning, tokens and rate limits without any secret' do
    users(:regular_user).update!(role: 'super_admin')
    AiHealthCheck.create!(status: 'error', key_state: 'expired', error_code: 'api_key_expired', model_state: 'available',
      configured_model: 'deepseek-v4-flash', free_models: %w[beam-free glm-5.3-flash-free], free_model_count: 2, checked_at: 2.minutes.ago)
    AiAgentRun.create!(outcome: 'ok', tokens_in: 1234, tokens_out: 56, occurred_at: 1.hour.ago)
    AiAgentRun.create!(outcome: 'rate_limited', error_type: 'rate_limited', occurred_at: 30.minutes.ago)
    get system_path
    assert_response :success
    assert_select '#ai-health h2', /AI health/
    assert_select '#ai-health [role=alert]', /API key has expired/
    assert_select '#ai-health', /1,234/
    assert_select '#ai-health', /Not working/
    assert_select '#ai-health li', 'beam-free'
    assert_select '#ai-health form[action=?]', check_system_ai_health_path
    assert_select '#ai-health [role=img][aria-label^=?]', 'Tokens per day'
    assert_no_match(/Bearer|\bsk-/, response.body)
  end

  test 'AI health card before any check offers a check and explains there is none' do
    users(:regular_user).update!(role: 'super_admin')
    get system_path
    assert_select '#ai-health', /No provider check has run yet/
  end

  test 'check now queues a provider check, throttled' do
    users(:regular_user).update!(role: 'super_admin')
    assert_enqueued_with(job: AiHealthCheckJob, args: ['manual']) { post check_system_ai_health_path }
    assert_redirected_to system_path(anchor: 'ai-health')
    AiHealthCheck.create!(status: 'ok', checked_at: 5.seconds.ago)
    assert_no_enqueued_jobs(only: AiHealthCheckJob) { post check_system_ai_health_path }
    assert_match(/just checked/, flash[:notice])
  end

  test 'a store admin cannot queue an AI health check' do
    assert_no_enqueued_jobs(only: AiHealthCheckJob) { post check_system_ai_health_path }
    assert_redirected_to root_path
  end

  test 'store admin cannot view instance diagnostics despite the system permission' do
    assert users(:regular_user).can?('system.read')
    get system_path
    assert_redirected_to root_path
    assert_match(/don't have permission/, flash[:alert])
  end

  test 'reader cannot view system health' do
    User.create!(
      email: 'sysreader@example.com',
      password: 'password123',
      role: 'reader',
      tenant: tenants(:default_tenant)
    )
    delete logout_path
    post login_path, params: { email: 'sysreader@example.com', password: 'password123' }

    get system_path
    assert_redirected_to root_path
    assert_match(/don't have permission/, flash[:alert])
  end

  test 'system presenter collects metrics' do
    presenter = SystemPresenter.new
    assert presenter.cpu_count.positive?
    assert presenter.mem_total_mb.positive?
    assert presenter.disk_used_pct >= 0
    assert presenter.db_max_connections.positive?
    assert presenter.sync_success_rate >= 0
  end
end
