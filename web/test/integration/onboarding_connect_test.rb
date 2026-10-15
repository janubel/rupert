# frozen_string_literal: true

require 'test_helper'

class OnboardingConnectTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Onboard Co', subdomain: 'onboardco')
    User.create!(email: 'ob@example.com', password: 'password123', role: 'admin',
      tenant_id: @tenant.id, name: 'OB')
    post login_path, params: { email: 'ob@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
    EnvStore::MANAGED_KEYS.each do |key|
      setting = Setting.find_by(key: key, tenant_id: @tenant.id)
      setting&.destroy
    end
  end

  test 'onboarding page shows inline credential form when unconfigured' do
    get onboarding_path
    assert_response :success
    assert_select 'form[action=?]', onboarding_connect_path
    assert_select 'input[name=shopify_client_id]'
    assert_select 'input[name=shopify_client_secret]'
    assert_select 'input[name=square_access_token]'
    assert_select 'button[type=submit]', /Save connection details/
    assert_select 'p', /Saving does not start a sync, test credentials or charge a payment/
  end

  test 'saving only square keys keeps onboarding open with guidance' do
    assert_no_enqueued_jobs only: SyncJob do
      post onboarding_connect_path, params: { square_access_token: 'EAAA-test-token' }
    end
    assert_redirected_to onboarding_path
    follow_redirect!
    assert_match(/Add your Shopify client ID/, flash[:notice].to_s)
    assert_equal 'EAAA-test-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN', '')
  end

  test 'saving shopify keys configures locally without starting a sync' do
    assert_no_enqueued_jobs only: SyncJob do
      post onboarding_connect_path, params: {
        shopify_client_id: 'cid-123',
        shopify_client_secret: 'secret-456',
        square_access_token: 'EAAA-square'
      }
    end
    assert_redirected_to root_path
    assert_equal 'cid-123', EnvStore.fetch('SHOPIFY_CLIENT_ID', '')
    assert_equal 'secret-456', EnvStore.fetch('SHOPIFY_CLIENT_SECRET', '')
    assert_match(/Start a sync/, flash[:notice])
  end

  test 'blank fields are ignored so partial updates never wipe saved keys' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'existing-id')
    post onboarding_connect_path, params: { shopify_client_id: '', square_access_token: 'new-token' }
    assert_redirected_to onboarding_path
    assert_equal 'existing-id', EnvStore.fetch('SHOPIFY_CLIENT_ID', '')
  end

  test 'readers cannot replace connection credentials or start a sync' do
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'existing-square-token')
    reader = User.create!(email: 'onboarding-reader@example.com', password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    assert_no_enqueued_jobs only: SyncJob do
      post onboarding_connect_path, params: { square_access_token: 'replacement-token', shopify_client_secret: 'stolen-secret' }
    end
    assert_redirected_to root_path
    assert_match(/settings permission/, flash[:alert])
    assert_equal 'existing-square-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN', '')
    assert_nil Setting.find_by(tenant_id: @tenant.id, key: 'SHOPIFY_CLIENT_SECRET')
  end

  test 'suspended stores cannot change credentials' do
    @tenant.update!(status: 'suspended')
    assert_no_difference -> { Setting.where(tenant_id: @tenant.id).count } do
      assert_no_enqueued_jobs only: SyncJob do
        post onboarding_connect_path, params: { shopify_client_id: 'cid', shopify_client_secret: 'secret' }
      end
    end
    assert_response :forbidden
    assert_includes response.body, 'workspace is inactive'
    assert_nil session[:user_id]
  end

  test 'deactivated accounts cannot save connection details' do
    User.find_by!(email: 'ob@example.com').update!(active: false)
    assert_no_difference -> { Setting.where(tenant_id: @tenant.id).count } do
      post onboarding_connect_path, params: { square_access_token: 'replacement-token' }
    end
    assert_redirected_to login_path
  end

  test 'credential errors never echo secret values back into the page' do
    EnvStore.stubs(:set).raises(StandardError, 'unsafe-detail-secret-123')
    post onboarding_connect_path, params: { square_access_token: 'unsafe-detail-secret-123' }
    assert_redirected_to onboarding_path
    assert_match(/Could not save connection details/, flash[:alert])
    refute_includes flash[:alert], 'unsafe-detail-secret-123'
    refute_includes response.body, 'unsafe-detail-secret-123'
  end

  test 'dashboard is reachable once configured' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'cid')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'sec')
    get onboarding_path
    assert_redirected_to root_path
  end
end
