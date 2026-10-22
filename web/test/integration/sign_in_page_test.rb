# frozen_string_literal: true

require 'test_helper'

# Everyone signs in with Google; email + password is folded away for setup.
class SignInPageTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @tenant.update!(subdomain: 'herbal') if @tenant.subdomain.blank?
    GoogleOauthService.stubs(:configured?).returns(true)
  end

  teardown { Current.reset }

  test 'a workspace address leads with Google, folds the password form away and offers no sign-up' do
    host! "#{@tenant.subdomain}.example.com"
    get login_path
    assert_response :success
    assert_select "a[href='#{google_auth_path}']", /Continue with Google/
    assert_select 'details.login-password:not([open]) form[action=?] input[name=email]:not([autofocus])', login_path
    assert_select 'details.login-password summary', 'Sign in with email and password'
    assert_select "a[href='#{start_path}']", 0
  end

  test 'the main Rupert site still offers creating an account' do
    host! 'example.com'
    get login_path
    assert_select "a[href='#{start_path}']", 'Create a free account'
  end

  test 'a failed password sign-in shows the form again, open and filled in' do
    host! "#{@tenant.subdomain}.example.com"
    post login_path, params: { email: 'admin@example.com', password: 'wrong' }
    assert_response :unprocessable_entity
    assert_select 'details.login-password[open] input[name=email][value=?]', 'admin@example.com'
  end

  test 'without Google sign-in the password form is open, and ?password=1 opens it on request' do
    host! "#{@tenant.subdomain}.example.com"
    GoogleOauthService.stubs(:configured?).returns(false)
    get login_path
    assert_select "a[href='#{google_auth_path}']", 0
    assert_select 'details.login-password[open] input[name=email][autofocus]'
    GoogleOauthService.stubs(:configured?).returns(true)
    get login_path(password: 1)
    assert_select 'details.login-password[open]'
  end

  test 'password sign-in still works' do
    host! "#{@tenant.subdomain}.example.com"
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
    assert_response :redirect
    assert_not_equal login_path, URI(response.location).path
  end
end
