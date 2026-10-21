# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

class AskRupertFlowTest < ActionDispatch::IntegrationTest
  include AskRupertHelper
  include ActiveJob::TestHelper

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    sign_in(@user)
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password' }
  end

  def json = response.parsed_body

  def stub_model(*replies)
    provider = ScriptedProvider.new(replies)
    AskRupert::Providers::Opencode.any_instance.stubs(:complete).with { |**args, &block| provider.complete(**args, &block) && false }
    AskRupert::Providers.stubs(:for_turn).returns([provider])
    provider
  end

  def start_chat
    post ask_rupert_conversations_path, as: :json
    assert_response :created
    json['conversation']['id']
  end

  def ask(id, text, **extra)
    post ask_rupert_messages_path(id), params: { message: text, page_path: '/syncs' }.merge(extra), as: :json
  end

  test 'the header offers Ask Rupert beside Help, with a drawer' do
    get root_path
    assert_select 'button[aria-label="Ask Rupert"][data-action="click->ask-rupert#toggle"]'
    assert_select 'aside#ask-rupert-title, aside[aria-labelledby="ask-rupert-title"][role="dialog"]'
    assert_select '[data-controller~="ask-rupert"]'
  end

  test 'it is hidden when an administrator turns it off, and its endpoints close too' do
    Current.tenant = @tenant
    AskRupert::Config.update!('enabled' => '0')
    get root_path
    assert_select 'button[aria-label="Ask Rupert"]', count: 0
    get ask_rupert_path(format: :json)
    assert_response :not_found
  end

  test 'the panel loads its starter questions, a disclosure and the limits' do
    get ask_rupert_path(format: :json)
    assert_response :success
    assert_match(/cloud AI model/, json['disclosure'])
    assert_equal 4, json['starters'].size
    assert_includes json['starters'], AskRupertController::REPORT_STARTER
    assert_equal 20, json['limits']['count']
    assert_nil json['conversation']
  end

  test 'asking creates the turn, the job writes the reply, and polling shows it' do
    stub_model('Open [Sync](/syncs) to see each pull.')
    id = start_chat
    perform_enqueued_jobs do
      ask(id, 'Where do I see sync history?')
      assert_response :accepted
    end
    get ask_rupert_conversation_path(id), as: :json
    assert_equal %w[user assistant], json['messages'].map { |message| message['role'] }
    reply = json['messages'].last
    assert_equal 'done', reply['status']
    assert_includes reply['content'], '[Sync](/syncs)'
    assert_includes reply['links'].map { |link| link['path'] }, '/learning/sync'
    assert_equal false, json['busy']
    assert_equal 1, AskRupert::Usage.unscoped.where(user_id: @user.id, outcome: 'ok').count
  end

  test 'a reply still being written reports busy and a second question waits its turn' do
    id = start_chat
    ask(id, 'First question')
    assert_response :accepted
    assert_equal true, json['busy']
    ask(id, 'Second question')
    assert_response :too_many_requests
    assert_match(/still answering/, json['error'])
    assert_predicate response.headers['Retry-After'], :present?
  end

  test 'a stuck reply is turned into a failed one after a few minutes' do
    id = start_chat
    ask(id, 'First question')
    travel(AskRupert::Message::STALE_AFTER + 1.minute) do
      get ask_rupert_conversation_path(id), as: :json
      assert_equal 'failed', json['messages'].last['status']
      assert_equal false, json['busy']
    end
  end

  test 'light rate limit: friendly message, retry hint, and no lockout afterward' do
    Current.tenant = @tenant
    AskRupert::Config.update!('rate_limit_count' => '2', 'rate_limit_window_minutes' => '10')
    stub_model('One.', 'Two.', 'Three.')
    id = start_chat
    2.times do |i|
      perform_enqueued_jobs { ask(id, "Question #{i}") }
      assert_response :accepted
    end
    ask(id, 'Question 3')
    assert_response :too_many_requests
    assert_equal 'rate', json['limited']
    assert_match(/Give it/, json['error'])
    assert_operator json['retry_after'], :>, 0
    assert_equal 1, AskRupert::Usage.unscoped.where(user_id: @user.id, outcome: 'limited').count
    travel 11.minutes do
      stub_model('Back again.')
      perform_enqueued_jobs { ask(id, 'Later question') }
      assert_response :accepted
    end
  end

  test 'questions that are empty or too long are turned away without using up the allowance' do
    id = start_chat
    ask(id, '   ')
    assert_response :unprocessable_entity
    ask(id, 'x' * 1_001)
    assert_response :unprocessable_entity
    assert_match(/under 1000/, json['error'])
    assert_equal 0, AskRupert::Usage.unscoped.count
  end

  test 'conversations are private to their owner and to their workspace' do
    id = start_chat
    other = person('admin', email: 'intruder@example.com')
    delete logout_path
    sign_in(other)
    get ask_rupert_conversation_path(id), as: :json
    assert_response :not_found
    ask(id, 'let me in')
    assert_response :not_found
    delete ask_rupert_conversation_path(id), as: :json
    assert_response :not_found
    assert AskRupert::Conversation.unscoped.exists?(id)
  end

  test 'saved chats are listed for their owner only, newest first, without empty ones' do
    stub_model('One.', 'Two.')
    first = start_chat
    perform_enqueued_jobs { ask(first, 'first question') }
    start_chat # an empty chat is not worth listing
    second = start_chat
    perform_enqueued_jobs { ask(second, 'second question') }
    get '/ask_rupert/conversations', as: :json
    assert_response :success
    assert_equal ['second question', 'first question'], json['conversations'].map { |row| row['title'] }
    delete logout_path
    sign_in(person('admin', email: 'neighbour@example.com'))
    get '/ask_rupert/conversations', as: :json
    assert_empty json['conversations']
  end

  test 'the account menu offers Ask Rupert chats' do
    get root_path
    assert_select 'button[role="menuitem"]', text: /Ask Rupert chats/
  end

  test 'Clear deletes the chat and its messages, and New chat starts fresh' do
    stub_model('Hello.')
    id = start_chat
    perform_enqueued_jobs { ask(id, 'hi') }
    assert_difference -> { AskRupert::Message.unscoped.count }, -2 do
      delete ask_rupert_conversation_path(id), as: :json
      assert_response :no_content
    end
    get ask_rupert_path(format: :json)
    assert_nil json['conversation']
    second = start_chat
    assert_not_equal id, second
  end

  test 'the page the person is on is kept only if it is a plain in-app path' do
    id = start_chat
    ask(id, 'where am I', page_path: 'https://evil.example/x')
    assert_response :accepted
    assert_nil AskRupert::Message.unscoped.where(role: 'user').last.page_path
  end

  test 'sending a report files it with the chat attached, only because the person asked' do
    stub_model('TOOL_CALL: {"name":"file_report","arguments":{"kind":"bug","summary":"Sync page is blank","details":"Nothing loads"}}', 'I prepared a report for you to review.')
    id = start_chat
    assert_no_difference -> { AgentFeedback.unscoped.count } do
      perform_enqueued_jobs { ask(id, 'the sync page is blank, sign here please') }
    end
    get ask_rupert_conversation_path(id), as: :json
    reply = json['messages'].last
    assert_equal 'Sync page is blank', reply['report_draft']['summary']

    assert_difference -> { AgentFeedback.unscoped.count }, 1 do
      post ask_rupert_report_path(id), params: { message_id: reply['id'], kind: 'bug', summary: 'Sync page is blank', details: 'Nothing loads' }, as: :json
      assert_response :created
    end
    feedback = AgentFeedback.unscoped.order(:id).last
    assert_equal @user.id, feedback.user_id
    assert_equal 'Ask Rupert', feedback.agent_name
    assert_equal 'app', feedback.source
    assert_includes feedback.details, 'Nothing loads'
    transcript = feedback.attachments.unscope(where: :tenant_id).find_by(kind: 'conversation')
    assert_includes transcript.text_body, 'the sync page is blank'
    assert_includes transcript.text_body, 'I prepared a report for you to review.'
    task = Projects::Task.unscoped.find(feedback.task_id)
    assert_equal 'Rupert Feedback', Projects::Project.unscoped.find(task.project_id).name
    assert_includes task.title, 'Sync page is blank'
    get ask_rupert_conversation_path(id), as: :json
    assert json['messages'].last['report_draft']['filed']
  end

  test 'a report needs a summary and has a daily ceiling' do
    id = start_chat
    post ask_rupert_report_path(id), params: { kind: 'bug', summary: '' }, as: :json
    assert_response :unprocessable_entity
    post ask_rupert_report_path(id), params: { kind: 'nonsense', summary: 'abc def' }, as: :json
    assert_response :unprocessable_entity
    AskRupert::Reporter::DAILY_LIMIT.times { post ask_rupert_report_path(id), params: { kind: 'question', summary: 'Another question' }, as: :json }
    post ask_rupert_report_path(id), params: { kind: 'question', summary: 'One too many' }, as: :json
    assert_response :unprocessable_entity
    assert_match(/try again tomorrow/, json['error'])
  end

  test 'Rupert Chat is a permission: administrators have it, others only when it is granted' do
    assert_includes User::ROLE_PERMISSIONS['admin'], 'chat.use'
    assert_includes User.all_permissions, 'chat.use'
    delete logout_path
    manager = person('manager', email: 'mgr@example.com')
    sign_in(manager)
    get root_path
    assert_select 'button[aria-label="Ask Rupert"]', count: 0
    get ask_rupert_path(format: :json)
    assert_response :forbidden
    manager.update_permission_overrides!(User::ROLE_PERMISSIONS['manager'] + ['chat.use'])
    get root_path
    assert_select 'button[aria-label="Ask Rupert"]'
    get ask_rupert_path(format: :json)
    assert_response :success
  end

  test 'the employee app has no Ask Rupert' do
    delete logout_path
    employee = person('employee', email: 'floor@example.com')
    sign_in(employee)
    get ask_rupert_path(format: :json)
    assert_response :forbidden
  end

  test 'the usage page shows counts but never message text, and only settings writers can change limits' do
    stub_model('Reply text that must not be listed.')
    id = start_chat
    perform_enqueued_jobs { ask(id, 'a private question about payroll') }
    get ask_rupert_usage_path
    assert_response :success
    assert_select 'h1', 'Ask Rupert usage'
    assert_match(/Admin/, response.body)
    assert_no_match(/private question|must not be listed/, response.body)

    patch ask_rupert_usage_path, params: { ask_rupert: { enabled: '1', provider_mode: 'cloud', rate_limit_count: '9', daily_cap: '50' } }
    assert_redirected_to ask_rupert_usage_path
    Current.tenant = @tenant
    assert_equal 9, AskRupert::Config.current['rate_limit_count']

    delete logout_path
    reader = person('reader', email: 'viewer@example.com')
    sign_in(reader)
    patch ask_rupert_usage_path, params: { ask_rupert: { rate_limit_count: '1' } }
    assert_redirected_to root_path
    Current.tenant = @tenant
    assert_equal 9, AskRupert::Config.current['rate_limit_count']
  end

  test 'chats are saved by default; a retention window removes old ones and keeps recent ones' do
    Current.tenant = @tenant
    old = AskRupert::Conversation.create!(user: @user, last_message_at: 400.days.ago)
    assert_equal 0, AskRupert::Retention.purge!
    assert AskRupert::Conversation.exists?(old.id)
    old.destroy
    AskRupert::Config.update!('retention_days' => '30')
    old = AskRupert::Conversation.create!(user: @user, last_message_at: 40.days.ago)
    old.messages.create!(user: @user, role: 'user', content: 'old')
    fresh = AskRupert::Conversation.create!(user: @user, last_message_at: 2.days.ago)
    assert_equal 1, AskRupert::Retention.purge!
    assert_not AskRupert::Conversation.exists?(old.id)
    assert AskRupert::Conversation.exists?(fresh.id)
    assert_equal 0, AskRupert::Message.where(conversation_id: old.id).count
  end
end
