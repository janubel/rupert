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
    assert_redirected_to root_path
    assert_equal @owner.id, session[:user_id]
    assert_equal 'linked-google-subject', @identity.reload.google_subject
    assert_equal 'owner@company.example', @owner.reload.email
    assert_equal 'super_admin', @owner.role
    refute OauthAllowedDomain.unscoped.exists?(domain: 'gmail.com')
    log = AccessLog.unscoped.order(:id).last
    assert_equal @owner.id, log.user_id
    assert_equal @identity.email, log.email
  end

  test 'linked login works on its own workspace subdomain' do
    host! "#{@tenant.subdomain}.example.com"
    sign_in_google
    assert_redirected_to root_path
    assert_equal @owner.id, session[:user_id]
  end

  test 'canonical Google login remains available' do
    sign_in_google(email: @owner.email, subject: 'work-google-subject')
    assert_redirected_to root_path
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
    assert_redirected_to root_path
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

  private

  def sign_in_google(email: 'owner.personal@gmail.com', subject: 'linked-google-subject')
    get google_auth_path
    state = session[:oauth_state]
    GoogleOauthService.expects(:exchange_code!).returns('email' => email, 'sub' => subject, 'name' => 'Owner')
    get google_callback_path, params: { code: 'test-code', state: state }
  end
end
