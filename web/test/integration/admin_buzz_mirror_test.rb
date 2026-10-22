# frozen_string_literal: true

require 'test_helper'
require_relative '../support/buzz_chat_helper'

# The administrator GUI mirrors the same Buzz channel as the Team chat tab,
# through its own admin-gated page and JSON endpoint.
class AdminBuzzMirrorTest < ActionDispatch::IntegrationTest
  include BuzzChatHelper

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @t0 = Time.now.to_i - 600
  end

  teardown do
    stop_buzz_relay
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def sign_in_admin
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
  end

  def sign_in_role(role, permissions:)
    user = User.create!(tenant: @tenant, email: "#{role}-mirror@example.com", role: role, password: 'password123', name: "#{role} Person")
    user.update_permission_overrides!(permissions)
    post login_path, params: { email: user.email, password: 'password123' }
    user
  end

  def json = response.parsed_body

  test 'signed-out visitors are sent to sign in' do
    get admin_buzz_mirror_path
    assert_redirected_to login_path
  end

  test 'people without settings.write cannot see the mirror or use its endpoint' do
    start_buzz_relay
    sign_in_role('manager', permissions: ['dashboard.read', 'buzz.read'])
    get admin_buzz_mirror_path
    assert_response :forbidden
    get admin_buzz_mirror_messages_path
    assert_response :forbidden
    post admin_buzz_mirror_messages_path, params: { message: 'hi' }, as: :json
    assert_response :forbidden
    get buzz_path
    assert_select "a[href='#{admin_buzz_mirror_path}']", 0
  end

  test 'the mirror shows the Team chat UI wired to the admin endpoint' do
    start_buzz_relay
    @relay.add(@relay.message(@alice, 'hello from Buzz', at: @t0))
    sign_in_admin

    get admin_buzz_mirror_path
    assert_response :success
    assert_select '[data-controller~=buzz-chat][data-buzz-chat-url-value=?]', admin_buzz_mirror_messages_path
    assert_select 'textarea#buzz-message'
    assert_select 'h1', /Buzz mirror/
    assert_select "a[href='#{admin_buzz_mirror_path}'][aria-current='page']"
    assert_select "a[href='#{buzz_chat_path}']"
    refute_includes response.body, 'hello from Buzz', 'messages stay out of the page markup'
  end

  test 'the mirror syncs the channel through its own endpoint' do
    start_buzz_relay
    @relay.add(@relay.message(@alice, 'mirrored', at: @t0))
    sign_in_admin

    get admin_buzz_mirror_messages_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal ['mirrored'], json['messages'].map { |m| m['text'] }
    assert_equal 'ready', json['status']['state']
    assert json['status']['synced_at']
    assert json['status']['can_post']
  end

  test 'admins can post through the mirror and it shows up in Buzz' do
    start_buzz_relay
    sign_in_admin

    post admin_buzz_mirror_messages_path, params: { message: 'hello from the mirror' }, as: :json
    assert_response :created
    assert_equal BuzzAgent.public_key_hex, @relay.published.last['pubkey']
    assert_match(/ via Rupert: hello from the mirror\z/, @relay.published.last['content'])

    get admin_buzz_mirror_messages_path
    posted = json['messages'].last
    assert_equal 'hello from the mirror', posted['text']
    assert posted['mine'] && posted['via_rupert'] && posted['agent']
  end

  test 'a bad cursor is refused' do
    start_buzz_relay
    sign_in_admin
    get admin_buzz_mirror_messages_path, params: { before: 'nonsense' }
    assert_response :unprocessable_entity
  end
end
