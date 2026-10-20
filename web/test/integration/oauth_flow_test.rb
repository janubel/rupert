# frozen_string_literal: true

require 'test_helper'

class OauthFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'OAuth Co', subdomain: "oauthco#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(domain: 'cybersecuritypilot.org', tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
  end

  test 'authorize redirects to Google with a state token' do
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/o/oauth2/auth?dummy=1')
    get google_auth_path
    assert_redirected_to('https://accounts.google.com/o/oauth2/auth?dummy=1')
    assert_not_nil session[:oauth_state]
  end

  test 'callback signs in an existing super admin from an allowed domain' do
    host! "#{@tenant.subdomain}.example.com"
    sean = User.create!(email: 'sean.dolbec@cybersecuritypilot.org', name: 'Sean Dolbec', role: 'super_admin',
      password: 'password123', tenant_id: @tenant.id)
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
                      .with('code123', redirect_uri: google_callback_url)
                      .returns('email' => 'sean.dolbec@cybersecuritypilot.org', 'name' => 'Sean Dolbec')

    get google_callback_path, params: { code: 'code123', state: state }
    assert_redirected_to(platform_path)
    assert_equal sean.id, session[:user_id]
  end

  test 'callback auto-provisions an employee for a new allowed-domain user' do
    host! "#{@tenant.subdomain}.example.com"
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
                      .with('code123', redirect_uri: google_callback_url)
                      .returns('email' => 'new.person@cybersecuritypilot.org', 'name' => 'New Person')

    get google_callback_path, params: { code: 'code123', state: state }
    assert_redirected_to(employee_app_path)
    created = User.find_by(email: 'new.person@cybersecuritypilot.org')
    assert_not_nil created
    assert_equal 'employee', created.role
    assert_equal session[:user_id], created.id
  end

  test 'callback rejects email on a non-allowed domain' do
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
                      .with('code123', redirect_uri: google_callback_url)
                      .returns('email' => 'someone@evil.com', 'name' => 'Someone')

    get google_callback_path, params: { code: 'code123', state: state }
    assert_redirected_to(login_path)
    assert_nil User.find_by(email: 'someone@evil.com')
  end

  test "a domain allowed by one tenant doesn't sign in users on another tenant" do
    other = Tenant.create!(name: 'Other Co', subdomain: "other#{SecureRandom.hex(4)}")
    host! "#{other.subdomain}.example.com"
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
                      .with('code123', redirect_uri: google_callback_url)
                      .returns('email' => 'someone@cybersecuritypilot.org', 'name' => 'Someone')

    get google_callback_path, params: { code: 'code123', state: state }
    assert_redirected_to(login_path)
    assert_nil User.find_by(email: 'someone@cybersecuritypilot.org')
  end

  test "callback doesn't sign into a same-email account that belongs to another tenant" do
    other = Tenant.create!(name: 'Other Co', subdomain: "other#{SecureRandom.hex(4)}")
    other_user = User.create!(email: 'shared@cybersecuritypilot.org', name: 'Shared', role: 'reader',
      password: 'password123', tenant_id: other.id)
    host! "#{@tenant.subdomain}.example.com"
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
                      .with('code123', redirect_uri: google_callback_url)
                      .returns('email' => 'shared@cybersecuritypilot.org', 'name' => 'Shared')

    get google_callback_path, params: { code: 'code123', state: state }
    assert_redirected_to(login_path)
    assert_nil session[:user_id]
    refute_equal other_user.id, session[:user_id]
    log = AccessLog.unscoped.order(:id).last
    assert_equal 'account belongs to another tenant', log.detail
  end

  test 'authorize records a Google attempt in the access log' do
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/o/oauth2/auth?dummy=1')
    get google_auth_path
    assert_redirected_to('https://accounts.google.com/o/oauth2/auth?dummy=1')
    log = AccessLog.order(:id).last
    assert_equal 'google', log.source
    assert_equal 'attempt', log.status
    assert_equal '127.0.0.1', log.ip
  end

  test 'callback rejects a mismatched state' do
    GoogleOauthService.expects(:exchange_code!).never
    get google_callback_path, params: { code: 'code123', state: 'wrong-state', hd: 'evilcorp.com' }
    assert_redirected_to(login_path)
    log = AccessLog.unscoped.order(:id).last
    assert_equal 'google', log.source
    assert_equal 'failure', log.status
    assert_equal 'evilcorp.com', log.domain
    assert_includes log.detail, 'state check'
  end

  test 'callback rejects a deactivated user' do
    host! "#{@tenant.subdomain}.example.com"
    inactive = User.create!(email: 'gone@cybersecuritypilot.org', name: 'Gone', role: 'reader',
      password: 'password123', active: false, tenant_id: @tenant.id)
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
                      .with('code123', redirect_uri: google_callback_url)
                      .returns('email' => 'gone@cybersecuritypilot.org', 'name' => 'Gone')

    get google_callback_path, params: { code: 'code123', state: state }
    assert_redirected_to(login_path)
    refute_equal inactive.id, session[:user_id]
  end
end
