# frozen_string_literal: true

require 'test_helper'

class PrivateDomainSignupTest < ActionDispatch::IntegrationTest
  setup do
    @domain = "private#{SecureRandom.hex(4)}.org"
    @attributes = { workspace_name: 'Private company', requested_subdomain: "private#{SecureRandom.hex(4)}", domain: @domain }
    @info = { 'email' => "owner@#{@domain}", 'name' => 'Private owner', 'email_verified' => true, 'sub' => SecureRandom.uuid }
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
  end

  teardown { Current.reset }

  test 'public signup collects company intent and requires Google verification' do
    get signup_path
    assert_response :success
    assert_select 'form[action=?]', signup_path
    assert_includes response.body, 'Referral attribution'
    assert_equal 'no-store', response.headers['Cache-Control']
    post signup_path, params: { workspace_signup: @attributes.merge(status: 'approved', referral_domain: 'attacker.org') }
    assert_redirected_to 'https://accounts.google.com/'
    assert_equal @attributes.stringify_keys, session[:workspace_signup_intent]
    assert session[:oauth_state].present?
    assert session[:oauth_started_at].present?
  end

  test 'verified signup records pending request but never signs in or creates a tenant' do
    start_signup
    assert_no_difference ['Tenant.count', 'User.count'] do
      assert_difference 'WorkspaceSignup.count', 1 do
        finish_signup
      end
    end
    assert_response :success
    assert_includes response.body, 'Workspace request pending'
    refute_includes response.body, @info['email']
    refute_includes response.body, 'workspace_signup_id'
    assert_nil session[:user_id]
    assert_nil session[:workspace_signup_intent]
    assert_nil session[:oauth_state]
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, WorkspaceSignup.last.referral_domain
  end

  test 'callback is single use and rejects wrong or expired state before provider exchange' do
    start_signup
    state = session[:oauth_state]
    GoogleOauthService.expects(:exchange_code!).never
    get google_callback_path, params: { state: 'forged', code: 'code' }
    assert_redirected_to login_path
    assert_nil session[:workspace_signup_intent]
    get google_callback_path, params: { state: state, code: 'code' }
    assert_redirected_to login_path
    start_signup
    state = session[:oauth_state]
    travel 11.minutes do
      get google_callback_path, params: { state: state, code: 'code' }
      assert_redirected_to login_path
    end
    assert_nil session[:workspace_signup_intent]
  end

  test 'unverified and mismatched identity create no request' do
    [@info.merge('email_verified' => false), @info.merge('email' => 'owner@different-company.org')].each do |info|
      start_signup
      assert_no_difference 'WorkspaceSignup.count' do
        finish_signup(info: info)
      end
      assert_response :redirect
      assert_nil session[:user_id]
    end
  end

  test 'consumer domain invalid shape and reserved names are rejected before Google' do
    GoogleOauthService.expects(:auth_url).never
    [@attributes.merge(domain: 'gmail.com'), @attributes.merge(domain: 'https://company.org'), @attributes.merge(requested_subdomain: 'admin')].each do |attributes|
      post signup_path, params: { workspace_signup: attributes }
      assert_response :unprocessable_entity
      assert_nil session[:workspace_signup_intent]
    end
  end

  test 'ordinary sign in clears signup purpose so it cannot submit a workspace' do
    start_signup
    get google_auth_path
    assert_nil session[:workspace_signup_intent]
    assert_no_difference 'WorkspaceSignup.count' do
      finish_signup
    end
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'root resolves exact existing user workspace when multiple workspaces exist' do
    tenant = Tenant.create!(name: 'Company owner', subdomain: "existing#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(tenant_id: tenant.id, domain: @domain)
    user = User.create!(tenant: tenant, email: @info['email'], name: 'Owner', role: 'admin', password: 'password123')
    Tenant.create!(name: 'Unrelated', subdomain: "unrelated#{SecureRandom.hex(4)}")
    get google_auth_path
    finish_signup
    assert_redirected_to root_path
    assert_equal user.id, session[:user_id]
  end

  test 'unique active domain may create employee with referral but ambiguous domain cannot' do
    tenant = Tenant.create!(name: 'Allowed company', subdomain: "allowed#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(tenant_id: tenant.id, domain: @domain)
    get google_auth_path
    finish_signup
    user = User.find_by!(email: @info['email'])
    assert user.employee?
    assert_equal tenant.id, user.tenant_id
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, user.referral_domain
    delete logout_path
    other = Tenant.create!(name: 'Other company', subdomain: "other#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(tenant_id: other.id, domain: @domain)
    get google_auth_path
    assert_no_difference 'User.count' do
      finish_signup(info: @info.merge('email' => "unknown@#{@domain}"))
    end
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'inactive workspace does not sign in existing or auto-created users' do
    tenant = Tenant.create!(name: 'Suspended company', subdomain: "suspended#{SecureRandom.hex(4)}", status: 'suspended')
    OauthAllowedDomain.create!(tenant_id: tenant.id, domain: @domain)
    user = User.create!(tenant: tenant, email: @info['email'], name: 'Owner', role: 'admin', password: 'password123')
    get google_auth_path
    finish_signup
    assert_redirected_to login_path
    refute_equal user.id, session[:user_id]
    get google_auth_path
    assert_no_difference('User.count') { finish_signup(info: @info.merge('email' => "unknown@#{@domain}")) }
    assert_redirected_to login_path
  end

  test 'approved owner must use the Google identity reviewed for that workspace' do
    platform_tenant = Tenant.create!(name: 'Platform', subdomain: "platform#{SecureRandom.hex(4)}")
    platform_owner = User.create!(tenant: platform_tenant, email: "platform-owner#{SecureRandom.hex(4)}@platform-owner.org",
      name: 'Platform owner', role: 'super_admin', password: 'password123')
    signup = WorkspaceSignupProvisioner.request_signup(info: @info, attributes: @attributes)
    approved = WorkspaceSignupProvisioner.approve(signup: signup, actor: platform_owner, lock_version: 0)
    owner = User.find_by!(tenant_id: approved.tenant_id, email: @info['email'])

    get google_auth_path
    assert_no_difference 'User.count' do
      finish_signup(info: @info.merge('sub' => 'different-google-identity'))
    end
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_includes flash[:alert], 'does not match the approved workspace owner'

    get google_auth_path
    finish_signup
    assert_redirected_to root_path
    assert_equal owner.id, session[:user_id]
  end

  test 'approved identity binding does not apply to another tenant or unrelated reader' do
    platform_tenant = Tenant.create!(name: 'Platform', subdomain: "platform#{SecureRandom.hex(4)}")
    platform_owner = User.create!(tenant: platform_tenant, email: "platform-owner#{SecureRandom.hex(4)}@platform-owner.org",
      name: 'Platform owner', role: 'super_admin', password: 'password123')
    signup = WorkspaceSignupProvisioner.request_signup(info: @info, attributes: @attributes)
    approved = WorkspaceSignupProvisioner.approve(signup: signup, actor: platform_owner, lock_version: 0)
    other_tenant = Tenant.create!(name: 'Other workspace', subdomain: "other#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(tenant_id: other_tenant.id, domain: @domain)
    # A legacy account transferred to another workspace is not governed by
    # a stale approval record belonging to the former workspace.
    reader = User.find_by!(email: @info['email'])
    reader.update!(tenant: other_tenant, role: 'reader')
    host! "#{other_tenant.subdomain}.example.com"
    get google_auth_path
    finish_signup(info: @info.merge('sub' => 'reader-google-identity'))
    assert_redirected_to root_path
    assert_equal reader.id, session[:user_id]
    refute_equal approved.tenant_id, reader.tenant_id
  end

  private

  def start_signup
    post signup_path, params: { workspace_signup: @attributes }
    assert_redirected_to 'https://accounts.google.com/'
  end

  def finish_signup(info: @info)
    GoogleOauthService.stubs(:exchange_code!).returns(info)
    get google_callback_path, params: { code: 'verified-code', state: session[:oauth_state] }
  end
end
