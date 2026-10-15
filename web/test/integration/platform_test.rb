# frozen_string_literal: true

require 'test_helper'

class PlatformTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = User.create!(tenant: @tenant, email: 'platform-owner@example.org', password: 'password123', role: 'super_admin')
    @other = Tenant.create!(name: 'Other company', subdomain: 'other-platform-company', status: 'active',
      referral_domain: WorkspaceSignup::REFERRAL_DOMAIN)
    @other_admin = User.create!(tenant: @other, email: 'other-owner@other-company.org', password: 'password123', role: 'admin',
      referral_domain: WorkspaceSignup::REFERRAL_DOMAIN)
    Current.user = @owner
    sign_in(@owner)
  end

  teardown { Current.reset }

  test 'anonymous dashboard and review requests are private before the login redirect' do
    anonymous = open_session
    anonymous.get '/platform'
    anonymous.assert_redirected_to login_path
    assert_privacy(anonymous.response)
    anonymous.post '/platform/signups/999999/approve', params: { lock_version: 0 }
    anonymous.assert_redirected_to login_path
    assert_privacy(anonymous.response)
    refute_includes anonymous.response.body, 'Other company'
  end

  test 'only fresh active super admin role with active home workspace can see global data' do
    sign_in(users(:regular_user))
    users(:regular_user).update_permission_overrides!(%w[settings.read settings.write system.read system.write])
    get '/platform'
    assert_response :forbidden
    assert_privacy(response)
    refute_includes response.body, 'Other company'
    sign_in(@owner)
    @owner.update!(role: 'admin')
    get '/platform'
    assert_response :forbidden
    assert_raises(ActiveRecord::RecordNotFound) { InstanceOverview.call(actor: @owner) }
    @owner.update!(role: 'super_admin')
    @tenant.update!(status: 'suspended')
    get '/platform'
    assert_response :forbidden
    assert_raises(ActiveRecord::RecordNotFound) { InstanceOverview.call(actor: @owner) }
    @tenant.update!(status: 'active')
    @owner.update!(active: false)
    get '/platform'
    assert_redirected_to login_path
    assert_privacy(response)
    assert_raises(ActiveRecord::RecordNotFound) { InstanceOverview.call(actor: @owner) }
  end

  test 'overview totals span workspaces and use explicit recent creation intervals' do
    travel_to Time.current.change(usec: 0) do
      User.update_all(created_at: 8.days.ago)
      Tenant.update_all(created_at: 31.days.ago)
      @other.update!(created_at: 30.days.ago, status: 'suspended')
      @other_admin.update!(created_at: 7.days.ago, active: false)
      User.create!(tenant: @other, email: 'new-user@other-company.org', password: 'password123', role: 'reader', created_at: 1.day.ago)
      User.create!(tenant: @other, email: 'future-user@other-company.org', password: 'password123', role: 'reader', created_at: 1.day.from_now)
      OauthAllowedDomain.create!(tenant_id: @other.id, domain: 'other-company.org')
      request_signup
      data = InstanceOverview.call(actor: @owner)
      totals = data.fetch(:totals)
      assert_equal Tenant.count, totals[:workspaces]
      assert_equal Tenant.where(status: 'active').count, totals[:active_workspaces]
      assert_equal 1, totals[:inactive_workspaces]
      assert_equal User.count, totals[:accounts]
      assert_equal User.where(active: true).count, totals[:active_accounts]
      assert_equal 2, totals[:new_accounts]
      assert_equal 1, totals[:new_workspaces]
      assert_equal 1, totals[:pending_signups]
      assert_equal 1, totals[:allowed_domains]
      other_row = data.fetch(:workspaces).find { |row| row[:workspace].id == @other.id }
      assert_equal 3, other_row[:accounts]
      assert_equal 1, other_row[:allowed_domains]
      get '/platform'
      assert_response :success
      assert_select "tr[data-workspace-id='#{@other.id}']", /Other company/
      assert_select '[data-metric=new_accounts] p', text: '2'
      assert_includes response.body, WorkspaceSignup::REFERRAL_DOMAIN
      assert_includes response.body, 'Not recorded (legacy)'
    end
  end

  test 'API token totals count usable credentials without exposing any secrets or provider details' do
    token, secret = ApiAccessToken.issue(attributes: { name: 'PRIVATE_TOKEN_NAME', scopes: ['roadmap:read'] }, user: @other_admin, tenant: @other)
    assert token.persisted?
    revoked, = ApiAccessToken.issue(attributes: { name: 'Revoked token', scopes: ['roadmap:read'] }, user: @other_admin, tenant: @other)
    revoked.update!(revoked_at: Time.current)
    expired, = ApiAccessToken.issue(attributes: { name: 'Expired token', scopes: ['roadmap:read'], expires_at: 1.day.from_now }, user: @other_admin, tenant: @other)
    ApiAccessToken.unscoped.where(id: expired.id).update_all(expires_at: 1.day.ago)
    PosConnection.create!(tenant_id: @other.id, provider: 'valmar', account_reference: 'PRIVATE_MERCHANT_REFERENCE')
    data = InstanceOverview.call(actor: @owner)
    assert_equal 3, data[:totals][:issued_api_tokens]
    assert_equal 1, data[:totals][:active_api_tokens]
    assert_equal 1, data[:totals][:provider_setups]
    @other_admin.update!(active: false)
    assert_equal 0, InstanceOverview.call(actor: @owner)[:totals][:active_api_tokens]
    get '/platform'
    assert_response :success
    [secret, token.token_digest, token.token_hint, 'PRIVATE_TOKEN_NAME', 'PRIVATE_MERCHANT_REFERENCE',
      ApplicationRecord.connection.pool.db_config.database].each do |private_value|
      refute_includes response.body, private_value
    end
    assert_includes response.body, 'does not establish payment readiness'
  end

  test 'snapshot uses bounded request and workspace lists and safely escapes owner supplied text' do
    signup = request_signup(name: '<script>PRIVATE_APPLICANT</script>', workspace: '<script>PRIVATE_COMPANY</script>')
    21.times do |index|
      Tenant.create!(name: "Bounded company #{index}", subdomain: "bounded-company-#{index}")
      request_signup(index: index + 1)
    end
    get '/platform'
    assert_response :success
    assert_privacy(response)
    assert_select 'tr[data-signup-id]', count: 20
    assert_select 'tr[data-workspace-id]', count: 20
    assert_select 'form input[name=lock_version]', count: 40
    assert_select 'form[data-turbo=false]', minimum: 40
    assert_select 'meta[name=turbo-cache-control][content=no-cache]'
    older_link = css_select('a').find { |link| link.text == 'Older pending requests' }
    assert older_link
    get older_link['href']
    assert_response :success
    assert_select 'tr[data-signup-id]', count: 2
    assert_select "tr[data-signup-id='#{signup.id}']"
    assert_includes response.body, '&lt;script&gt;PRIVATE_APPLICANT&lt;/script&gt;'
    refute_includes response.body, '<script>PRIVATE_APPLICANT</script>'
    assert_select 'a', text: 'Newest pending requests'
    get '/platform', params: { before_signup_id: '-100' }
    assert_response :bad_request
  end

  test 'platform reviews pending signup once and creates isolated owner workspace with exact attribution' do
    signup = request_signup
    assert_difference ['Tenant.count', 'User.count', 'OauthAllowedDomain.unscoped.count'], 1 do
      post "/platform/signups/#{signup.id}/approve", params: { lock_version: signup.lock_version }
      assert_redirected_to '/platform'
    end
    signup.reload
    assert_equal 'approved', signup.status
    assert_equal @owner.id, signup.reviewer_id
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, signup.tenant.referral_domain
    new_owner = User.find_by!(email: signup.email)
    assert new_owner.admin?
    assert_equal signup.tenant_id, new_owner.tenant_id
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, new_owner.referral_domain
    assert_no_difference ['Tenant.count', 'User.count', 'WorkspaceSignupEvent.count'] do
      post "/platform/signups/#{signup.id}/approve", params: { lock_version: signup.lock_version }
      assert_redirected_to '/platform'
    end
    assert_includes flash[:alert], 'already reviewed'
    get '/platform'
    assert_select "tr[data-signup-id='#{signup.id}'] form", count: 0
  end

  test 'rejected and stale requests cannot create workspaces and normal admin cannot review' do
    signup = request_signup
    sign_in(@other_admin)
    assert_no_difference ['Tenant.count', 'WorkspaceSignupEvent.count'] do
      post "/platform/signups/#{signup.id}/reject", params: { lock_version: signup.lock_version }
      assert_response :forbidden
    end
    sign_in(@owner)
    assert_no_difference ['Tenant.count', 'WorkspaceSignupEvent.count'] do
      post "/platform/signups/#{signup.id}/approve", params: { lock_version: 99 }
      assert_redirected_to '/platform'
    end
    assert_equal 'pending', signup.reload.status
    post "/platform/signups/#{signup.id}/reject", params: { lock_version: signup.lock_version }
    assert_redirected_to '/platform'
    assert_equal 'rejected', signup.reload.status
    post '/platform/signups/999999/reject', params: { lock_version: 0 }
    assert_response :not_found
    assert_privacy(response)
    post "/platform/signups/#{signup.id}/approve"
    assert_response :bad_request
    assert_privacy(response)
  end

  test 'instance section only displays configured label safe database metrics and recorded evidence' do
    old_label = ENV['RUPERT_INSTANCE_LABEL']
    ENV['RUPERT_INSTANCE_LABEL'] = 'SER8 · Incus'
    finished = 5.minutes.ago
    SyncRun.create!(tenant_id: @other.id, mode: 'full', status: 'success', startedAt: 10.minutes.ago, finishedAt: finished, error: 'PRIVATE_SYNC_DETAILS')
    Current.set(tenant: nil) do
      BackupLog.create!(tenant_id: nil, status: 'success', startedAt: 10.minutes.ago, finishedAt: finished,
        fileSize: 4096, fileName: 'PRIVATE_BACKUP_FILENAME', driveUrl: 'https://private.example.org/PRIVATE_BACKUP_LINK')
    end
    BackupLog.create!(tenant_id: @other.id, status: 'success', startedAt: 1.minute.ago, finishedAt: Time.current,
      fileSize: 9999, fileName: 'UNTRUSTED_TENANT_BACKUP')
    data = InstanceOverview.call(actor: @owner)
    assert_equal 'SER8 · Incus', data[:instance][:label]
    assert_equal ApplicationRecord.connection.adapter_name, data[:instance][:adapter]
    assert_in_delta finished.to_f, data[:last_sync].to_f, 0.01
    assert_equal 4096, data[:last_backup][:bytes]
    get '/platform'
    assert_response :success
    assert_includes response.body, 'SER8 · Incus'
    assert_includes response.body, 'not proof that a restore has been tested'
    assert_includes response.body, 'not a count of verified live operating-system processes'
    %w[PRIVATE_SYNC_DETAILS PRIVATE_BACKUP_FILENAME PRIVATE_BACKUP_LINK].each { |value| refute_includes response.body, value }
    ENV['RUPERT_INSTANCE_LABEL'] = "Invalid\nlabel"
    assert_equal 'Not configured', InstanceOverview.call(actor: @owner)[:instance][:label]
  ensure
    ENV['RUPERT_INSTANCE_LABEL'] = old_label
  end

  private

  def sign_in(user)
    delete logout_path
    post login_path, params: { email: user.email, password: user == users(:regular_user) ? 'password' : 'password123' }
  end

  def request_signup(index: 0, name: 'New Company Owner', workspace: 'New private company')
    WorkspaceSignupProvisioner.request_signup(info: { 'email' => "owner@private-company-#{index}.org", 'name' => name,
      'sub' => "platform-test-subject-#{index}", 'email_verified' => true }, attributes: {
        workspace_name: workspace, requested_subdomain: "private-company-#{index}", domain: "private-company-#{index}.org"
      })
  end

  def assert_privacy(result)
    assert_equal 'no-store', result.headers['Cache-Control']
    assert_equal 'no-referrer', result.headers['Referrer-Policy']
    assert_equal 'DENY', result.headers['X-Frame-Options']
    assert_includes result.headers['X-Robots-Tag'], 'noarchive'
    assert_match(/frame-ancestors 'none'/, result.headers['Content-Security-Policy'])
  end
end
