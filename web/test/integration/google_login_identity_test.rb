# frozen_string_literal: true

require 'test_helper'

class GoogleLoginIdentityTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Linked login', subdomain: "linked#{SecureRandom.hex(4)}")
    @domain = OauthAllowedDomain.create!(domain: 'company.example', tenant_id: @tenant.id)
    @owner = User.create!(email: 'owner@company.example', name: 'Owner', role: 'super_admin',
      password: 'test-password', tenant_id: @tenant.id)
    @identity = @owner.google_login_identities.create!(email: 'owner.personal@gmail.com')
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
  end

  teardown do
    Current.reset
  end

  test 'exact linked Gmail signs into the existing account and pins its Google subject' do
    assert_no_difference 'User.count' do
      sign_in_google
    end
    assert_redirected_to platform_path
    assert_equal @owner.id, session[:user_id]
    assert_equal 'linked-google-subject', @identity.reload.google_subject
    assert_equal 'owner@company.example', @owner.reload.email
    assert_equal 'super_admin', @owner.role
    refute OauthAllowedDomain.unscoped.exists?(domain: 'gmail.com')
    log = AccessLog.unscoped.order(:id).last
    assert_equal @owner.id, log.user_id
    assert_equal @identity.email, log.email
  end

  test 'linked Google login honors the permitted bookkeeping landing page' do
    @owner.update!(dashboard_config: { 'start_page' => 'bookkeeping' })
    sign_in_google
    assert_redirected_to books_check_path
  end

  test 'linked login works on its own workspace subdomain' do
    host! "#{@tenant.subdomain}.example.com"
    sign_in_google
    assert_redirected_to platform_path
    assert_equal @owner.id, session[:user_id]
  end

  test 'canonical Google login remains available' do
    sign_in_google(email: @owner.email, subject: 'work-google-subject')
    assert_redirected_to platform_path
    assert_equal @owner.id, session[:user_id]
    assert_nil @identity.reload.google_subject
  end

  test 'unlinked Gmail is still rejected and never provisioned' do
    assert_no_difference 'User.count' do
      sign_in_google(email: 'someone.else@gmail.com')
    end
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'linked login cannot cross workspace boundaries' do
    other = Tenant.create!(name: 'Other linked workspace', subdomain: "otherlinked#{SecureRandom.hex(4)}")
    host! "#{other.subdomain}.example.com"
    sign_in_google
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_nil @identity.reload.google_subject
  end

  test 'deactivated account cannot use an alias' do
    @owner.update!(active: false)
    sign_in_google
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_nil @identity.reload.google_subject
  end

  test 'inactive workspace cannot use an alias' do
    @tenant.update!(status: 'inactive')
    sign_in_google
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'removing the canonical domain also disables linked sign-in' do
    @domain.destroy!
    sign_in_google
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'a different Google subject cannot take over a linked email' do
    @identity.update!(google_subject: 'original-subject')
    sign_in_google(subject: 'different-subject')
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_equal 'original-subject', @identity.reload.google_subject
  end

  test 'an established identity can sign in again' do
    @identity.update!(google_subject: 'linked-google-subject')
    sign_in_google
    assert_redirected_to platform_path
    assert_equal @owner.id, session[:user_id]
  end

  test 'a missing Google subject cannot sign into a linked account' do
    sign_in_google(subject: nil)
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_nil @identity.reload.google_subject
  end

  test 'a later canonical account collision fails closed' do
    User.create!(email: @identity.email, role: 'reader', password: 'test-password', tenant_id: @tenant.id)
    sign_in_google
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_nil @identity.reload.google_subject
  end

  test 'revoking an alias removes its access immediately' do
    @identity.destroy!
    sign_in_google
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'an alias cannot claim another existing account email' do
    other = User.create!(email: 'other@company.example', role: 'reader', password: 'test-password', tenant_id: @tenant.id)
    identity = @owner.google_login_identities.new(email: other.email)
    refute identity.valid?
    assert_includes identity.errors[:email], 'already belongs to another account'
  end

  test 'alias emails normalize and remain globally unique' do
    duplicate = @owner.google_login_identities.new(email: '  OWNER.PERSONAL@GMAIL.COM ')
    refute duplicate.valid?
    assert_includes duplicate.errors[:email], 'has already been taken'
  end

  test 'explicit same-email approval signs an existing Gmail administrator into the same account' do
    account = User.create!(email: 'finance.admin@gmail.com', role: 'admin', password: 'test-password', tenant_id: @tenant.id)
    identity = account.google_login_identities.create!(email: account.email)
    assert_no_difference 'User.count' do
      sign_in_google(email: account.email, subject: 'approved-finance-subject')
    end
    assert_redirected_to root_path
    assert_equal account.id, session[:user_id]
    assert_equal 'approved-finance-subject', identity.reload.google_subject
    assert_equal 'admin', account.reload.role
    assert account.can?('finance.read')
    assert account.can?('finance.write')
    refute OauthAllowedDomain.unscoped.exists?(domain: 'gmail.com')
  end

  test 'an existing Gmail account without explicit approval cannot sign in with Google' do
    account = User.create!(email: 'finance.admin@gmail.com', role: 'admin', password: 'test-password', tenant_id: @tenant.id)
    sign_in_google(email: account.email)
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'same-email approval does not bypass inactive account workspace or cross-workspace checks' do
    account = User.create!(email: 'finance.admin@gmail.com', role: 'admin', password: 'test-password', tenant_id: @tenant.id)
    identity = account.google_login_identities.create!(email: account.email)
    account.update!(active: false)
    sign_in_google(email: account.email)
    assert_nil session[:user_id]
    assert_nil identity.reload.google_subject
    account.update!(active: true)
    @tenant.update!(status: 'inactive')
    sign_in_google(email: account.email)
    assert_nil session[:user_id]
    assert_nil identity.reload.google_subject
    @tenant.update!(status: 'active')
    other = Tenant.create!(name: 'Other explicit login', subdomain: "otherexact#{SecureRandom.hex(4)}")
    host! "#{other.subdomain}.example.com"
    sign_in_google(email: account.email)
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_nil identity.reload.google_subject
  end

  test 'same-email approval keeps subject binding and revocation effective' do
    account = User.create!(email: 'finance.admin@gmail.com', role: 'admin', password: 'test-password', tenant_id: @tenant.id)
    identity = account.google_login_identities.create!(email: account.email, google_subject: 'original-subject')
    sign_in_google(email: account.email, subject: 'different-subject')
    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_equal 'original-subject', identity.reload.google_subject
    identity.destroy!
    sign_in_google(email: account.email, subject: 'original-subject')
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'moving a Google link expires the old admin session and signs in the employee with private timesheets' do
    host! "#{@tenant.subdomain}.example.com"
    sign_in_google
    assert_equal @owner.id, session[:user_id]
    Current.tenant = @tenant
    employee = User.create!(tenant: @tenant, email: @identity.email, name: 'Employee', role: 'employee', password: 'test-password')
    worker = People::Employee.create!(user: employee, first_name: 'Own', last_name: 'Worker')
    other = People::Employee.create!(first_name: 'Other', last_name: 'Private')
    monday = Date.current.beginning_of_week
    own_sheet = worker.timesheets.create!(period_start: monday, period_end: monday + 6)
    other_sheet = other.timesheets.create!(period_start: monday, period_end: monday + 6)
    @identity.update!(user: employee)

    get login_path
    assert_response :success
    assert_nil session[:user_id]
    get ctrax_pos_path
    assert_redirected_to login_path

    sign_in_google
    assert_redirected_to employee_app_path
    assert_equal employee.id, session[:user_id]
    get ctrax_pos_path
    assert_response :success
    assert_select 'header.pos-topbar form[action=?] button', logout_path, text: 'Sign out'
    get people_timesheets_path(view: 'list')
    assert_response :success
    assert_select 'a[href=?]', people_timesheet_path(own_sheet)
    assert_select 'a[href=?]', people_timesheet_path(other_sheet), count: 0
    get people_timesheet_path(other_sheet)
    assert_response :not_found
    get people_timesheet_path(other_sheet, format: :csv)
    assert_response :not_found
    assert_equal 'super_admin', @owner.reload.role
  end

  test 'revoking a linked identity expires an already authenticated session' do
    sign_in_google
    @identity.destroy!
    get login_path
    assert_response :success
    assert_nil session[:user_id]
  end

  test 'password changes expire administrator browser sessions' do
    sign_in_google
    @owner.update!(password: 'replacement-password')
    get login_path
    assert_response :success
    assert_nil session[:user_id]
  end

  private

  def sign_in_google(email: 'owner.personal@gmail.com', subject: 'linked-google-subject')
    get google_auth_path
    state = session[:oauth_state]
    GoogleOauthService.expects(:exchange_code!).returns('email' => email, 'sub' => subject, 'name' => 'Owner')
    get google_callback_path, params: { code: 'test-code', state: state }
  end
end
