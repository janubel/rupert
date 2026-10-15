# frozen_string_literal: true

require 'test_helper'

class DriveSetupInstructionsTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: '2024-10',
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.tenant = nil }

  test 'drive setup shows easy instructions with direct links for the platform operator' do
    users(:regular_user).update!(role: 'super_admin')
    get settings_path
    assert_response :success
    assert_select "a[href='https://console.cloud.google.com/']"
    assert_select "a[href='https://console.cloud.google.com/apis/library/drive.googleapis.com']"
    assert_select "a[href='https://console.cloud.google.com/apis/credentials/consent']"
    assert_select "a[href='https://console.cloud.google.com/apis/credentials']"
    assert_match(/Easy setup/, response.body)
    assert_match(/GOOGLE_DRIVE_CLIENT_ID=/, response.body)
    assert_match(/GOOGLE_DRIVE_CLIENT_SECRET=/, response.body)
  end
end
