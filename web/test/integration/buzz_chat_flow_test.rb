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
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
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
    assert_select "nav[aria-label='Buzz sections'] a[href='#{buzz_chat_path}']", 1
    assert_select "nav[aria-label='Buzz sections'] a[aria-current='page']", text: /Agent/
  end

  test 'when Buzz is not set up the tab explains it instead of failing' do
    sign_in_admin
    get buzz_chat_path
    assert_response :success
    assert_select 'section[role=status] h2', /not set up yet/
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
    assert_select 'section[role=status] h2', /No channel chosen/
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

  test 'posting goes out as the agent with the sender named, and shows up in the chat' do
    start_buzz_relay
    sign_in_admin
    post buzz_chat_messages_path, params: { message: 'hello from Rupert' }, as: :json
    assert_response :created
    assert_equal BuzzAgent.public_key_hex, @relay.published.last['pubkey']
    assert_match(/ via Rupert: hello from Rupert\z/, @relay.published.last['content'])

    get buzz_chat_messages_path
    posted = json['messages'].last
    assert posted['mine'] && posted['via_rupert'] && posted['agent']
    assert_equal 'hello from Rupert', posted['text']
  end

  test 'a mention of Rupert queues the shared answer path' do
    start_buzz_relay
    sign_in_admin
    post buzz_chat_messages_path, params: { message: 'hello @rupert' }, as: :json
    assert_response :created

    job = enqueued_jobs.find { |entry| entry[:job] == BuzzMirrorReplyJob }
    assert job, 'expected the mirror reply job'
    assert_equal BuzzAgent.channel_id, job[:args][2]
    assert_equal 'hello @rupert', job[:args][3]
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
end
