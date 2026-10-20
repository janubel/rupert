# frozen_string_literal: true

require 'test_helper'

class CustomerCommerceTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    @operator = User.create!(tenant: Tenant.create!(name: 'Platform', subdomain: 'platform-home'), email: 'support@example.org', password: 'password123', role: 'super_admin')
  end
  teardown { Current.reset }

  test 'anonymous root presents real prices and free signup' do
    get root_path
    assert_response :success
    assert_includes response.body, '$499'
    assert_includes response.body, '$249.50'
    assert_includes response.body, '$2,994'
    assert_includes response.body, '12-month commitment'
    get start_path
    assert_response :success
  end

  test 'Google registration verifies identity and provisions isolated tenant records atomically' do
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    post start_path, params: { registration: { workspace_name: 'New business', requested_subdomain: 'fresh-business', role: 'super_admin' } }
    assert_redirected_to 'https://accounts.google.com/'
    GoogleOauthService.stubs(:exchange_code!).returns({ 'email' => 'newperson@gmail.com', 'sub' => 'verified-new-person', 'email_verified' => true, 'name' => 'New person' })
    assert_difference ['Tenant.count', 'User.count', 'CustomerSubscription.count'], 1 do
      get google_callback_path, params: { state: session[:oauth_state], code: 'verified-code' }
    end
    assert_redirected_to workspace_path
    user = User.find_by!(email: 'newperson@gmail.com')
    assert_equal 'admin', user.role
    assert_equal user.id, session[:user_id]
    assert_empty OauthAllowedDomain.unscoped.where(domain: 'gmail.com')
    assert_equal 'verified-new-person', user.google_login_identities.first.google_subject
    get billing_path
    assert_response :success
    assert_includes response.body, 'being configured'
  end

  test 'registration rejects unverified identities and operator mailbox self provisioning' do
    PlatformOwnerIdentities.stubs(:emails).returns(['reserved@operations.example'])
    info = { 'email' => 'new@gmail.com', 'sub' => 'new', 'email_verified' => false }
    assert_no_difference ['Tenant.count', 'User.count'] do
      assert_raises(GoogleOauthService::ExchangeError) { VerifiedWorkspaceRegistration.call(info: info, attributes: {}) }
      assert_raises(GoogleOauthService::ExchangeError) { VerifiedWorkspaceRegistration.call(info: info.merge('email_verified' => true, 'email' => 'reserved@operations.example'), attributes: {}) }
    end
  end

  test 'registration rollback leaves no partial tenant if account fails' do
    assert_no_difference 'Tenant.count' do
      assert_raises(ActiveRecord::RecordInvalid) do
        VerifiedWorkspaceRegistration.call(info: { 'email' => 'bad-email', 'sub' => 'new', 'email_verified' => true }, attributes: { 'workspace_name' => 'Failed', 'requested_subdomain' => 'failed-registration' })
      end
    end
  end

  test 'billing and grants cannot be used by other roles or anonymously' do
    get billing_path
    assert_redirected_to login_path
    post login_path, params: { email: @operator.email, password: 'password123' }
    get billing_path
    assert_response :forbidden
    post support_access_path, params: { support_user_id: @operator.id, reason: 'Self grant' }
    assert_response :forbidden
  end

  test 'owner issued referral mode cannot create extra codes even for paying customers' do
    previous = ENV['RUPERT_APPROVED_REFERRAL_CODES']
    ENV['RUPERT_APPROVED_REFERRAL_CODES'] = 'LEGACY-INVITE'
    CustomerSubscription.create!(tenant: @tenant, status: 'active')
    post login_path, params: { email: @owner.email, password: 'password' }
    assert_no_difference 'CustomerReferral.count' do
      post billing_referral_path
    end
    assert_redirected_to billing_path
    assert_includes flash[:alert], 'issued by Rupert support'
    CustomerReferral.create!(tenant: @tenant, code: 'LEGACY-INVITE')
    assert_no_difference 'CustomerReferral.count' do
      post billing_referral_path
    end
    assert_equal 'Your referral code is ready.', flash[:notice]
  ensure
    previous.nil? ? ENV.delete('RUPERT_APPROVED_REFERRAL_CODES') : ENV['RUPERT_APPROVED_REFERRAL_CODES'] = previous
  end

  test 'customer grants expire and revoke while support has no write or credential access' do
    host! 'support-customer.example.com'
    post login_path, params: { email: @operator.email, password: 'password123' }
    @tenant.update!(subdomain: 'support-customer')
    get '/inventory'
    assert_response :forbidden
    grant = SupportAccessGrant.create!(tenant: @tenant, granted_by: @owner, support_user: @operator, reason: 'Inventory help', expires_at: 1.hour.from_now)
    get '/inventory'
    assert_response :success
    assert SupportAccessEvent.exists?(support_access_grant: grant, action: 'viewed')
    get '/settings'
    assert_response :forbidden
    post '/source_syncs/square'
    assert_response :forbidden
    travel 61.minutes do
      get '/inventory'
      assert_response :forbidden
    end
    grant.update_columns(revoked_at: Time.current)
    get '/inventory'
    assert_response :forbidden
  end

  test 'customer can grant and revoke access with audit events' do
    post login_path, params: { email: @owner.email, password: 'password' }
    post support_access_path, params: { support_user_id: @operator.id, reason: 'Help with inventory' }
    assert_redirected_to support_access_path
    grant = SupportAccessGrant.last
    assert_equal @tenant.id, grant.tenant_id
    get support_access_path
    assert_response :success
    delete revoke_support_access_path(grant)
    assert_redirected_to support_access_path
    assert grant.reload.revoked_at
    assert_equal %w[granted revoked], SupportAccessEvent.where(support_access_grant: grant).order(:id).pluck(:action)
  end

  test 'cross tenant bearer tokens are never valid support access' do
    Current.tenant = @tenant
    token, secret = ApiAccessToken.issue(attributes: { name: 'Bypass', scopes: ['inventory:read'] }, user: @operator, tenant: @tenant)
    assert_nil secret
    assert token.errors.any?
  end
  test 'operator enters customer workspace only through a valid grant and exits after revocation' do
    post login_path, params: { email: @operator.email, password: 'password123' }
    post enter_platform_support_path(@tenant.id)
    assert_response :forbidden
    grant = SupportAccessGrant.create!(tenant: @tenant, granted_by: @owner, support_user: @operator, reason: 'Read inventory', expires_at: 1.hour.from_now)
    get platform_path
    assert_response :success
    assert_select 'form[action=?]', enter_platform_support_path(@tenant.id)
    post enter_platform_support_path(@tenant.id)
    assert_redirected_to inventory_index_path
    get inventory_index_path
    assert_response :success
    assert_includes response.body, 'Read-only customer support'
    post source_sync_path('square')
    assert_response :forbidden
    grant.update_columns(revoked_at: Time.current)
    get inventory_index_path
    assert_response :forbidden
    delete leave_platform_support_path
    assert_redirected_to platform_path
    assert_nil session[:support_tenant_id]
    get platform_path
    assert_response :success
  end

  test 'full instance backup downloads cannot bypass customer support permission' do
    CustomerSubscription.create!(tenant: @tenant)
    post login_path, params: { email: @operator.email, password: 'password123' }
    BackupService.expects(:snapshot_path).never
    get backup_settings_path
    assert_response :forbidden
    get drive_status_settings_path
    assert_response :forbidden
    get drive_logs_settings_path
    assert_response :forbidden
    post drive_backup_settings_path
    assert_response :forbidden
  end
end
