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
end
