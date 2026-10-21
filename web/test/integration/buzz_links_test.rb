# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

class BuzzLinksTest < ActionDispatch::IntegrationTest
  include AskRupertHelper

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    AskRupert::Config.update!('buzz_enabled' => '1')
    @admin = person('admin', email: 'buzz-link-admin@example.com')
    @key = SecureRandom.hex(32)
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password' }
  end

  def claim_for(user, key = @key)
    Current.tenant = @tenant
    _, code = BuzzIdentity.issue_code!(user)
    BuzzIdentity.claim(code: code, pubkey: key).identity
  end

  test 'the Buzz page offers linking only while the switch is on' do
    sign_in(@admin)
    get buzz_path
    assert_select '#buzz-link'
    AskRupert::Config.update!('buzz_enabled' => '0')
    get buzz_path
    assert_select '#buzz-link', 0
  end

  test 'making a code shows it once, with the steps, and stores only a digest' do
    sign_in(@admin)
    post buzz_link_path
    assert_redirected_to buzz_path(anchor: 'buzz-link')
    follow_redirect!
    code = css_select('#buzz-link code').first.text.strip
    assert_match(/\A[2-9A-Z]{8}\z/, code)
    assert_select '#buzz-link', text: /direct message/
    assert_equal 1, BuzzIdentity.where(user_id: @admin.id, status: 'code').count
    assert_nil BuzzIdentity.where(user_id: @admin.id).pluck(:code_digest).find { |value| value == code }
    get buzz_path
    assert_select '#buzz-link', text: /Your code/, count: 0
  end

  test 'a waiting link shows the key to compare and is confirmed by its owner' do
    identity = claim_for(@admin)
    sign_in(@admin)
    get buzz_path
    assert_select '#buzz-link', text: /#{Regexp.escape(identity.npub)}/
    post confirm_buzz_link_path(identity)
    assert_redirected_to buzz_path(anchor: 'buzz-link')
    assert_equal 'active', identity.reload.status
    assert_equal @admin, BuzzIdentity.user_for(@key)
    assert_equal 'buzz_link_confirmed', ActivityLog.order(:id).last.action
  end

  test 'a linked account is listed with a way to remove it' do
    claim_for(@admin).confirm!
    BuzzIdentity.user_for(@key)
    sign_in(@admin)
    get buzz_path
    assert_response :success
    assert_select '#buzz-link', text: /Linked/
    assert_select '#buzz-link', text: /#{@key.first(4)}/
    assert_select "#buzz-link form[action^='/buzz/link/'] button", text: 'Remove link'
  end

  test 'declining or removing a link ends it' do
    identity = claim_for(@admin)
    sign_in(@admin)
    delete remove_buzz_link_path(identity)
    assert_equal 'revoked', identity.reload.status
    assert_nil BuzzIdentity.lookup(@key)
  end

  test 'nobody can confirm or remove someone else\'s link' do
    identity = claim_for(@admin)
    other = person('admin', email: 'buzz-link-other@example.com')
    sign_in(other)
    post confirm_buzz_link_path(identity)
    assert_equal 'pending', identity.reload.status
    delete remove_buzz_link_path(identity)
    assert_equal 'pending', identity.reload.status
  end

  test 'people without the Rupert Chat permission cannot make or confirm links' do
    cashier = person('cashier', email: 'buzz-link-cashier@example.com')
    sign_in(cashier)
    assert_no_difference -> { BuzzIdentity.unscoped.count } do
      post buzz_link_path
    end
    assert_response :forbidden
    get buzz_path
    assert_select '#buzz-link', 0
  end

  test 'with the switch off the endpoints are not there' do
    AskRupert::Config.update!('buzz_enabled' => '0')
    sign_in(@admin)
    post buzz_link_path
    assert_response :not_found
  end

  test 'an administrator can switch Buzz answers on from the usage page' do
    AskRupert::Config.update!('buzz_enabled' => '0')
    sign_in(@admin)
    patch ask_rupert_usage_path, params: { ask_rupert: { buzz_enabled: '1' } }
    assert AskRupert::Config.current.buzz_enabled?
    patch ask_rupert_usage_path, params: { ask_rupert: { buzz_enabled: '0' } }
    assert_not AskRupert::Config.current.buzz_enabled?
  end

  test 'it is off unless someone turns it on' do
    Setting.where(key: AskRupert::Config::KEY).delete_all
    assert_not AskRupert::Config.current.buzz_enabled?
    sign_in(@admin)
    get buzz_path
    assert_response :success
    assert_select '#buzz-link', 0
  end
end
