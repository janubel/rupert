# frozen_string_literal: true

require 'test_helper'

# Google knows one callback host (GoogleOauthService.sign_in_host). Sign-in and sign-up that start
# anywhere else (pos.rupertpos.com, rupertpos.com, the iPhone app) move there first.
class GoogleOauthHostTest < ActionDispatch::IntegrationTest
  CHALLENGE = 'a' * 43

  setup do
    @saved = ENV.fetch('RUPERT_GOOGLE_OAUTH_HOST', nil)
    ENV['RUPERT_GOOGLE_OAUTH_HOST'] = 'signin.example.com'
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
  end

  teardown do
    @saved ? ENV['RUPERT_GOOGLE_OAUTH_HOST'] = @saved : ENV.delete('RUPERT_GOOGLE_OAUTH_HOST')
    Current.reset
  end

  test 'Google sign-in on another host moves to the registered host with its parameters' do
    host! 'pos.example.com'
    get google_auth_path, params: { native_challenge: CHALLENGE }
    assert_redirected_to "https://signin.example.com/auth/google?native_challenge=#{CHALLENGE}"
    assert_nil session[:oauth_state], 'no state is left on the host Google will not return to'
  end

  test 'the registered host starts Google as before' do
    host! 'signin.example.com'
    get google_auth_path
    assert_redirected_to 'https://accounts.google.com/'
    assert session[:oauth_state].present?
  end

  test 'a web sign-up on another host carries the form to the registered host' do
    host! 'pos.example.com'
    post start_path, params: { registration: { workspace_name: 'Moved Shop', requested_subdomain: 'moved-shop' } }
    location = URI(response.location)
    assert_equal '/auth/google', location.path
    intent = Rack::Utils.parse_query(location.query)['intent']
    assert intent.present?

    host! 'signin.example.com'
    get google_auth_path, params: { intent: intent }
    assert_equal 'moved-shop', session[:registration_intent]['requested_subdomain']
    GoogleOauthService.stubs(:exchange_code!).returns('email' => 'moved.owner@gmail.com', 'sub' => 'moved-owner',
      'email_verified' => true, 'name' => 'Moved Owner')
    get google_callback_path, params: { code: 'code123', state: session[:oauth_state] }
    assert_redirected_to workspace_path
    assert_equal User.find_by!(email: 'moved.owner@gmail.com').id, session[:user_id]
  end

  test 'without a configured host nothing moves' do
    ENV.delete('RUPERT_GOOGLE_OAUTH_HOST')
    assert_nil GoogleOauthService.sign_in_host
    assert_not GoogleOauthService.sign_in_elsewhere?('pos.example.com')
  end
end
