# frozen_string_literal: true

require 'test_helper'

class ShopifyClientTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore.clear_cache!
  end

  teardown do
    Setting.where(key: 'SHOPIFY_SHOP_DOMAIN').delete_all
    EnvStore.clear_cache!
    Current.reset
  end

  test 'shop_domain prefers the managed setting, then the workspace record, and never a built-in default' do
    assert_equal 'testshop.myshopify.com', ShopifyClient.shop_domain

    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'other.myshopify.com')
    assert_equal 'other.myshopify.com', ShopifyClient.shop_domain

    EnvStore.set('SHOPIFY_SHOP_DOMAIN', nil)
    Current.tenant.update_columns(shopify_shop_domain: nil)
    error = assert_raises(ShopifyClient::Error) { ShopifyClient.shop_domain }
    assert_equal :invalid, error.reason
    assert_equal 'configuration', SyncFailure.category(error)
  end

  test 'the Admin API version is pinned once and shopify.app.toml agrees' do
    toml = File.read(Rails.root.join('..', 'shopify.app.toml'))
    pinned = toml[/^\s*api_version\s*=\s*"([^"]+)"/, 1]
    assert_equal SHOPIFY_ADMIN_API_VERSION, pinned, 'shopify.app.toml [webhooks] api_version must match config/shopify_api_version.rb'
    assert_equal SHOPIFY_ADMIN_API_VERSION, ShopifyClient::API_VERSION
    assert_equal SHOPIFY_ADMIN_API_VERSION, ShopifyApp.configuration.api_version
    assert_match(/\A\d{4}-(01|04|07|10)\z/, SHOPIFY_ADMIN_API_VERSION, 'Shopify releases quarterly versions')
  end

  test 'shopify.app.toml application_url resolves to the documented production host' do
    toml = File.read(Rails.root.join('..', 'shopify.app.toml'))
    assert_equal 'https://rupert.stoverparc.org', toml[/^application_url\s*=\s*"([^"]+)"/, 1]
  end
end
