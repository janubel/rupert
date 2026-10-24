# frozen_string_literal: true

require 'test_helper'

# The Rupert iPhone app (ios/): path configuration, native layout and the Google sign-in handoff.
class NativeAppTest < ActionDispatch::IntegrationTest
  VERIFIER = 'v' * 20 + 'erifier-abcdefghijklmnopqrstuvwxyz'

  setup do
    @tenant = Tenant.create!(name: 'Native Co', subdomain: "nativeco#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(domain: 'cybersecuritypilot.org', tenant_id: @tenant.id)
    host! "#{@tenant.subdomain}.example.com"
    @admin = User.create!(email: 'sean.dolbec@cybersecuritypilot.org', name: 'Sean Dolbec', role: 'super_admin',
      password: 'password123', tenant_id: @tenant.id)
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  teardown { Current.reset }

  def challenge = NativeSignIn.challenge_for(VERIFIER)

  def sign_in_through_sheet(email: @admin.email)
    get google_auth_path, params: { native_challenge: challenge }
    assert_equal challenge, session[:oauth_native_challenge]
    GoogleOauthService.stubs(:exchange_code!).returns('email' => email, 'name' => 'Someone')
    get google_callback_path, params: { code: 'code123', state: session[:oauth_state] }
  end

  def handed_off(name)
    uri = URI.parse(response.location)
    assert_equal 'rupert', uri.scheme
    Rack::Utils.parse_query(uri.query)[name]
  end

  test 'path configuration is public JSON with a catch-all rule' do
    get native_ios_path_configuration_path
    assert_response :success
    rules = response.parsed_body['rules']
    assert_equal ['.*'], rules.first['patterns']
    assert(rules.any? { |rule| rule['properties']['context'] == 'modal' })
  end

  test 'a signed-out app opening Home goes to sign-in, not the marketing page' do
    get root_path, headers: { 'User-Agent' => 'Mozilla/5.0 (iPhone) Rupert iOS/1.0.0; Hotwire Native iOS; Turbo Native iOS' }
    assert_redirected_to login_path
    get root_path
    assert_response :success
  end

  test 'the app layout drops the chrome the native tab bar replaces' do
    post login_path, params: { email: @admin.email, password: 'password123' }
    get root_path, headers: { 'User-Agent' => 'Mozilla/5.0 (iPhone) Hotwire Native iOS; Turbo Native iOS; bridge-components: []' }
    assert_includes response.body, 'native-app'
    get root_path
    assert_not_includes response.body, 'class="min-h-full native-app"'
  end

  test 'Google in the sheet hands a one-time code to the app, not a session' do
    sign_in_through_sheet
    code = handed_off('code')
    assert code.present?
    assert_nil session[:user_id], 'the browser sheet must not keep a Rupert session'

    post native_session_path, params: { code: code, verifier: VERIFIER }, as: :json
    assert_response :success
    assert_equal platform_path, response.parsed_body['location']
    assert_equal @admin.id, session[:user_id]
    assert_equal 'google', session[:auth_method]
  end

  test 'a code is useless without the verifier and works once' do
    sign_in_through_sheet
    code = handed_off('code')

    post native_session_path, params: { code: code, verifier: 'x' * 43 }, as: :json
    assert_response :unprocessable_entity
    assert_nil session[:user_id]

    post native_session_path, params: { code: code, verifier: VERIFIER }, as: :json
    assert_response :success
    reset!
    host! "#{@tenant.subdomain}.example.com"
    post native_session_path, params: { code: code, verifier: VERIFIER }, as: :json
    assert_response :unprocessable_entity
  end

  test 'an expired or tampered code is rejected' do
    sign_in_through_sheet
    code = handed_off('code')
    post native_session_path, params: { code: code.reverse, verifier: VERIFIER }, as: :json
    assert_response :unprocessable_entity

    travel 3.minutes do
      post native_session_path, params: { code: code, verifier: VERIFIER }, as: :json
      assert_response :unprocessable_entity
    end
  end

  test 'a refused Google account returns the reason to the app' do
    sign_in_through_sheet(email: 'someone@evil.com')
    assert_match(/allowed domain/, handed_off('error'))
    assert_nil User.find_by(email: 'someone@evil.com')
  end

  test 'a malformed challenge falls back to the ordinary web sign-in' do
    get google_auth_path, params: { native_challenge: 'short' }
    assert_nil session[:oauth_native_challenge]
    GoogleOauthService.stubs(:exchange_code!).returns('email' => @admin.email, 'name' => 'Sean')
    get google_callback_path, params: { code: 'code123', state: session[:oauth_state] }
    assert_redirected_to platform_path
    assert_equal @admin.id, session[:user_id]
  end

  NATIVE_UA = { 'User-Agent' => 'Mozilla/5.0 (iPhone) Rupert iOS/1.0.0; Hotwire Native iOS; Turbo Native iOS' }.freeze

  test 'sign-up in the app carries the form through the Google sheet and lands on the new workspace' do
    post start_path, params: { registration: { workspace_name: 'Native Shop', requested_subdomain: 'native-shop' } },
      headers: NATIVE_UA
    intent = Rack::Utils.parse_query(URI.parse(response.location).query)['intent']
    assert_equal '/auth/google', URI.parse(response.location).path
    assert intent.present?
    assert_nil session[:registration_intent], 'the web view keeps no half-finished sign-up'

    get google_auth_path, params: { native_challenge: challenge, intent: intent }
    assert_equal({ 'workspace_name' => 'Native Shop', 'requested_subdomain' => 'native-shop' }, session[:registration_intent])
    GoogleOauthService.stubs(:exchange_code!).returns('email' => 'native.owner@gmail.com', 'sub' => 'native-owner',
      'email_verified' => true, 'name' => 'Native Owner')
    assert_difference 'User.count', 1 do
      get google_callback_path, params: { code: 'code123', state: session[:oauth_state] }
    end
    code = handed_off('code')
    assert_nil session[:user_id]

    post native_session_path, params: { code: code, verifier: VERIFIER }, as: :json
    assert_response :success
    assert_equal workspace_path, response.parsed_body['location']
    assert_equal User.find_by!(email: 'native.owner@gmail.com').id, session[:user_id]
  end

  test 'a workspace request from the app returns the receipt as a message' do
    token = NativeSignIn.intent_token('workspace_signup', { 'workspace_name' => 'Requested', 'requested_subdomain' => 'requested-shop' })
    get google_auth_path, params: { native_challenge: challenge, intent: token }
    assert_equal 'requested-shop', session[:workspace_signup_intent]['requested_subdomain']
    GoogleOauthService.stubs(:exchange_code!).returns('email' => 'owner@requested.example', 'sub' => 'requested-owner',
      'email_verified' => true)
    WorkspaceSignupProvisioner.stubs(:request_signup).returns(WorkspaceSignup.new(status: 'pending'))
    get google_callback_path, params: { code: 'code123', state: session[:oauth_state] }
    assert_match(/waiting for platform owner review/, handed_off('message'))
    assert_nil session[:user_id]
  end

  test 'a forged or unknown intent is ignored' do
    get google_auth_path, params: { native_challenge: challenge, intent: 'not-a-token' }
    assert_nil session[:registration_intent]
    assert_nil session[:workspace_signup_intent]
    assert_nil NativeSignIn.read_intent(NativeSignIn.intent_token('registration', {}).reverse)
    assert_raises(ArgumentError) { NativeSignIn.intent_token('admin', {}) }
  end

  test 'landing paths stay on the instance' do
    code = NativeSignIn.issue(user: @admin, google_email: @admin.email, google_identity: nil, challenge: challenge,
      location: '//evil.example/x')
    _, _, _, location = NativeSignIn.redeem(code, VERIFIER)
    assert_nil location
  end
end
