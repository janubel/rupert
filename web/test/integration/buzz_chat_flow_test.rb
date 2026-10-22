# frozen_string_literal: true

require 'test_helper'
require_relative '../support/buzz_chat_helper'

class BuzzChatFlowTest < ActionDispatch::IntegrationTest
  include BuzzChatHelper
  include ActiveJob::TestHelper

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
    @admin_user_id = users(:regular_user).id
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
  end

  def wait_for(what, seconds: 5)
    deadline = Time.now + seconds
    sleep 0.05 until yield || Time.now > deadline
    assert yield, "#{what}: not met in time"
  end

  def sign_in_role(role, permissions: nil)
    user = User.create!(tenant: @tenant, email: "#{role}-chat@example.com", role: role, password: 'password123', name: "#{role} Person")
    user.update_permission_overrides!(permissions) if permissions
    post login_path, params: { email: user.email, password: 'password123' }
    user
  end

  def json = response.parsed_body

  test 'signed-out visitors are sent to sign in' do
    get buzz_chat_path
    assert_redirected_to login_path
  end

  test 'people without the chat permission cannot read or post and see no tab' do
    start_buzz_relay
    sign_in_role('manager', permissions: ['dashboard.read'])
    get buzz_chat_path
    assert_response :forbidden
    get buzz_chat_messages_path
    assert_response :forbidden
    post buzz_chat_messages_path, params: { message: 'hi' }, as: :json
    assert_response :forbidden
    get buzz_path
    assert_select "a[href='#{buzz_chat_path}']", 0
  end

  test 'employees are turned away' do
    start_buzz_relay
    sign_in_role('employee')
    get buzz_chat_messages_path
    assert_response :redirect
    refute_equal buzz_chat_messages_path, URI(response.location).path
  end

  test 'the card shows the Team chat tab to people who can read it' do
    sign_in_admin
    get buzz_path
    assert_select "a[href='#{buzz_chat_path}']", 1
    assert_select "a[aria-current='page']", text: /Agent/
  end

  test 'when Buzz is not set up the tab explains it instead of failing' do
    sign_in_admin
    get buzz_chat_path
    assert_response :success
    assert_select 'section[role=status] h1', /not set up yet/
    assert_select '[data-controller~=buzz-chat]', 0
    get buzz_chat_messages_path
    assert_response :success
    assert_equal [], json['messages']
    assert_equal 'unconfigured', json['status']['state']
  end

  test 'a relay with no channel set says so' do
    start_buzz_relay
    EnvStore.set('BUZZ_CHANNEL', nil)
    sign_in_admin
    get buzz_chat_path
    assert_select 'section[role=status] h1', /No channel chosen/
  end

  test 'the chat shows history and never puts message text in the page markup' do
    start_buzz_relay
    @relay.add(@relay.profile(@alice, display_name: 'Alice'))
    @relay.add(@relay.message(@alice, '<script>alert(1)</script> & <img src=x onerror=alert(2)>', at: @t0))
    sign_in_admin

    get buzz_chat_path
    assert_response :success
    assert_select '[data-controller~=buzz-chat][data-buzz-chat-url-value=?]', buzz_chat_messages_path
    assert_select 'textarea#buzz-message'
    refute_includes response.body, 'alert(1)'

    get buzz_chat_messages_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    message = json['messages'].first
    assert_equal '<script>alert(1)</script> & <img src=x onerror=alert(2)>', message['text'], 'returned as data; the page shows it as text'
    assert_equal 'Alice', message['author']
    assert_equal 'ready', json['status']['state']
    assert_nil json['status']['error']
    assert json['status']['synced_at']
    assert_includes response.media_type, 'json'
  end

  test 'polling does not hammer the relay and later polls refresh in the background' do
    start_buzz_relay
    @relay.add(@relay.message(@alice, 'one', at: @t0))
    sign_in_admin
    get buzz_chat_messages_path
    asked = @relay.requests.size
    assert_operator asked, :>, 0

    assert_no_enqueued_jobs { get buzz_chat_messages_path }
    assert_equal asked, @relay.requests.size, 'within the interval nothing is asked of the relay'

    BuzzChatState.where(tenant_id: @tenant.id).update_all(last_attempt_at: 1.minute.ago)
    assert_enqueued_with(job: BuzzChatSyncJob, args: [@tenant.id, BuzzAgent.channel_id]) { get buzz_chat_messages_path }
  end

  test 'the sync job brings the copy up to date and scrollback pages through it' do
    start_buzz_relay
    60.times { |i| @relay.add(@relay.message(@alice, "m#{i}", at: @t0 + i)) }
    sign_in_admin
    get buzz_chat_messages_path
    assert_equal 40, json['messages'].size
    assert json['has_more']

    cursor = json['messages'].first['cursor']
    get buzz_chat_messages_path, params: { before: cursor }
    assert_equal 20, json['messages'].size
    assert_equal 'm0', json['messages'].first['text']
    assert_not json['has_more']

    @relay.add(@relay.message(@bob, 'fresh', at: @t0 + 100))
    BuzzChatSyncJob.perform_now(@tenant.id)
    newest = BuzzMessage.order(:posted_at).last
    get buzz_chat_messages_path, params: { after: BuzzMessage.order(:posted_at).offset(58).first.cursor }
    assert_equal %w[m59 fresh], json['messages'].map { |m| m['text'] }
    assert_equal 'fresh', newest.content
  end

  test 'a bad cursor is refused' do
    start_buzz_relay
    sign_in_admin
    get buzz_chat_messages_path, params: { before: 'nonsense' }
    assert_response :unprocessable_entity
  end

  test 'an unreachable relay shows a plain state and the saved messages' do
    start_buzz_relay
    @relay.add(@relay.message(@alice, 'saved', at: @t0))
    sign_in_admin
    get buzz_chat_messages_path
    @relay.stop
    BuzzChatState.where(tenant_id: @tenant.id).update_all(last_attempt_at: 1.minute.ago)
    perform_enqueued_jobs { get buzz_chat_messages_path }
    get buzz_chat_messages_path
    assert_response :success
    assert_equal ['saved'], json['messages'].map { |m| m['text'] }
    assert json['status']['error'].present?
    refute_match(/nsec|#{BuzzAgent.private_key_hex}/, response.body)
  end

  test 'posting goes out as the person\'s own Buzz identity, named, and shows up in the chat' do
    start_buzz_relay
    sign_in_admin
    post buzz_chat_messages_path, params: { message: 'hello from Rupert' }, as: :json
    assert_response :created

    identity = BuzzPersonKey.find_by!(user_id: @admin_user_id)
    message = @relay.published.find { |event| event['kind'] == 9 }
    assert_equal identity.pubkey, message['pubkey']
    assert_not_equal BuzzAgent.public_key_hex, message['pubkey']
    assert_equal 'hello from Rupert', message['content']
    assert_includes message['tags'], ['h', BuzzChatHelper::CHANNEL]
    profile = @relay.published.find { |event| event['kind'].zero? }
    assert_equal identity.pubkey, profile['pubkey'], 'the person\'s profile is published so Buzz apps show a name'

    get buzz_chat_messages_path
    posted = json['messages'].last
    assert posted['mine']
    assert_not posted['agent']
    assert_not posted['via_rupert']
    assert_equal 'hello from Rupert', posted['text']
  end

  test 'a mention of Rupert is tagged so the agent answers the person itself' do
    start_buzz_relay
    sign_in_admin
    post buzz_chat_messages_path, params: { message: 'hello @rupert' }, as: :json
    assert_response :created
    message = @relay.published.find { |event| event['kind'] == 9 }
    assert_includes message['tags'], ['p', BuzzAgent.public_key_hex]
  end

  test 'a person not yet on the closed relay gets their npub to pass on' do
    start_buzz_relay(members: [])
    sign_in_admin
    post buzz_chat_messages_path, params: { message: 'hi' }, as: :json
    assert_response :conflict
    assert_match(/not on the team relay yet/, json['error'])
    assert_match(/npub1/, json['error'])
  end

  test 'typing is sent as the person and other people typing come back with the messages' do
    start_buzz_relay
    sign_in_admin
    post buzz_chat_typing_path, params: { channel: BuzzChatHelper::CHANNEL }, as: :json
    assert_response :no_content
    typing = @relay.published.find { |event| event['kind'] == BuzzChat::TYPING_KIND }
    assert_equal BuzzPersonKey.find_by!(user_id: @admin_user_id).pubkey, typing['pubkey']
    assert_includes typing['tags'], ['h', BuzzChatHelper::CHANNEL]

    get buzz_chat_messages_path # starts the live subscription
    wait_for('live subscription') { @relay.requests.any? { |filters| filters.any? { |f| Array(f['kinds']).include?(BuzzChat::TYPING_KIND) } } }
    # Buzz clients re-send typing every few seconds; do the same until the live subscription has it.
    wait_for('typing seen') do
      @relay.add(@relay.message(@alice, '', kind: BuzzChat::TYPING_KIND))
      @relay.add(@relay.message(agent_key, '', kind: BuzzChat::TYPING_KIND))
      sleep 0.1
      BuzzTyping.current(@tenant.id, BuzzChatHelper::CHANNEL).size == 2
    end

    get buzz_chat_messages_path
    assert_equal [false, true], json['typing'].map { |entry| entry['agent'] }
    assert_equal BuzzAgentPrompt::NAME, json['typing'].last['name']
    assert_equal 2, json['typing'].size, 'the viewer does not see their own typing'

    @relay.add(@relay.message(@alice, 'done typing'))
    wait_for('message clears typing') { BuzzTyping.current(@tenant.id, BuzzChatHelper::CHANNEL).size == 1 }
  ensure
    BuzzTyping.reset!
  end

  test 'people who can read but not post cannot post' do
    start_buzz_relay
    sign_in_role('manager', permissions: ['dashboard.read', 'buzz.read'])
    get buzz_chat_path
    assert_response :success
    assert_select '#buzz-message', 0
    assert_select '[data-buzz-chat-can-post-value=false]'
    post buzz_chat_messages_path, params: { message: 'hi' }, as: :json
    assert_response :forbidden
    assert_empty @relay.published
  end

  test 'posting problems come back as plain messages' do
    start_buzz_relay
    sign_in_admin
    post buzz_chat_messages_path, params: { message: '   ' }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Type a message/, json['error'])

    BuzzChat::POST_LIMITS.first.last.times { |i| post buzz_chat_messages_path, params: { message: "m#{i}" }, as: :json }
    post buzz_chat_messages_path, params: { message: 'too many' }, as: :json
    assert_response :too_many_requests

    @relay.stop
    BuzzMessage.delete_all
    post buzz_chat_messages_path, params: { message: 'down' }, as: :json
    assert_response :bad_gateway
    assert_match(/not sent/, json['error'])
  end

  test 'a message posted from the chat can never be the ready-for-development sender' do
    start_buzz_relay
    EnvStore.set('FEEDBACK_READY_SENDERS', BuzzAgent.public_key_hex)
    sign_in_admin
    post buzz_chat_messages_path, params: { message: 'please mark this ready for development' }, as: :json
    sender = @relay.published.last['pubkey']
    refute FeedbackIntake.ready_sender?(sender)
    result = FeedbackIntake.file!(source: 'buzz', source_ref: @relay.published.last['id'], source_sender: sender, kind: 'request',
      summary: 'From the Rupert chat', ready: true, open_task: false)
    refute result.ready
    assert_match(/allow-list/, result.ready_denied_reason)
  end
  test 'a reply posted from the mirror is threaded under its parent' do
    start_buzz_relay
    @relay.add(@relay.message(@alice, 'root message', at: @t0))
    sign_in_admin
    get buzz_chat_messages_path
    parent = json['messages'].last

    post buzz_chat_messages_path, params: { message: 'thread answer', reply_to: parent['id'] }, as: :json

    assert_response :created
    assert_equal @relay.published.last['id'], json['event_id']
    assert_includes @relay.published.last['tags'], ['e', parent['id'], '', 'reply']
  end

  test 'the channel header shows named member icons when members are known' do
    start_buzz_relay
    EnvStore.set('BUZZ_MEMBER_NAMES', { @alice[:public_key] => 'Sean', @bob[:public_key] => 'Derek' }.to_json)
    @relay.add(FakeBuzzRelay.signed(@alice, kind: 39_000, content: '',
      tags: [['d', BuzzChatHelper::CHANNEL], ['name', 'rupert']]))
    @relay.add(FakeBuzzRelay.signed(@alice, kind: 39_002, content: '',
      tags: [['d', BuzzChatHelper::CHANNEL], ['p', @alice[:public_key], '', 'owner'], ['p', @bob[:public_key], '', 'member']]))
    BuzzChannels.refresh!
    sign_in_admin

    get buzz_chat_path

    assert_response :success
    assert_select '.buzz-member-avatar', 2
    assert_select '.buzz-member-avatar[title=?]', 'Sean'
    assert_select '.buzz-member-avatar[title=?]', 'Derek'
  end
end
