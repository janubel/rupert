# frozen_string_literal: true

require 'test_helper'
require 'rake'

class ShopTest < ActiveSupport::TestCase
  test 'the Shopify token is encrypted at rest and decrypted on read' do
    shop = Shop.create!(shopify_domain: 'enc.myshopify.com', shopify_token: 'shpat_secret', refresh_token: 'refresh_secret')
    raw = Shop.connection.select_one(Shop.sanitize_sql_array(['SELECT shopify_token, refresh_token FROM shops WHERE id = ?', shop.id]))
    assert_not_equal 'shpat_secret', raw['shopify_token']
    assert_not_includes raw['shopify_token'], 'shpat_secret'
    assert_not_includes raw['refresh_token'].to_s, 'refresh_secret'
    assert_equal 'shpat_secret', Shop.find(shop.id).shopify_token
    assert_equal 'refresh_secret', Shop.find(shop.id).refresh_token
  end

  test 'rows written before encryption still read, and ops:encrypt_shop_tokens rewrites them' do
    Shop.connection.execute(Shop.sanitize_sql_array([
      'INSERT INTO shops (shopify_domain, shopify_token, created_at, updated_at) VALUES (?, ?, ?, ?)',
      'plain.myshopify.com', 'plaintext-token', Time.current, Time.current
    ]))
    shop = Shop.find_by!(shopify_domain: 'plain.myshopify.com')
    assert_equal 'plaintext-token', shop.shopify_token
    assert_not shop.encrypted_attribute?(:shopify_token)

    Rails.application.load_tasks unless Rake::Task.task_defined?('ops:encrypt_shop_tokens')
    silence_stream($stdout) { Rake::Task['ops:encrypt_shop_tokens'].execute }

    reloaded = Shop.find_by!(shopify_domain: 'plain.myshopify.com')
    assert reloaded.encrypted_attribute?(:shopify_token)
    assert_equal 'plaintext-token', reloaded.shopify_token
    raw = Shop.connection.select_value(Shop.sanitize_sql_array(['SELECT shopify_token FROM shops WHERE id = ?', reloaded.id]))
    assert_not_equal 'plaintext-token', raw
  end

  private

  def silence_stream(stream)
    old = stream.dup
    stream.reopen(File::NULL)
    yield
  ensure
    stream.reopen(old)
  end
end
