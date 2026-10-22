# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatAgentTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @room = TeamChat::Room.ensure_defaults!(@user)
  end

  teardown { Current.reset }

  def ask(text, parent_id: nil)
    TeamChat::Post.call(room: @room, user: @user, body: text, parent_id: parent_id).reply
  end

  test 'a mention gets a pending reply; a plain message does not' do
    assert_nil ask('hello team')
    reply = ask('@rupert where are timesheets?')
    assert reply.pending?
    assert_equal 'assistant', reply.author_kind
    assert_equal @user.id, reply.meta['asked_by']
  end

  test 'the reply calls a Rupert tool natively and streams the answer into the room' do
    requests = script_model({ tool: 'where_is', arguments: { query: 'timesheets' } }, { text: 'Timesheets are under Team. Open [Timesheets](/people/timesheets).' })
    reply = ask('@rupert where are timesheets?')

    TeamChat::Agent.new(reply, config: team_chat_config).run
    reply.reload

    assert_equal 'done', reply.status
    assert_includes reply.body, '[Timesheets](/people/timesheets)'
    assert_equal ['where_is'], reply.meta['tools']
    assert_equal 'ok', reply.meta['outcome']
    assert_equal 2, requests.size
    first = requests.first
    assert first['stream']
    assert_includes first['tools'].map { |tool| tool.dig('function', 'name') }, 'sales_summary'
    assert_equal 'system', first['messages'].first['role']
    assert_includes first['messages'].first['content'], 'You are Rupert'
    assert_match(/: @rupert where are timesheets\?\z/, first['messages'].last['content'])
    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert tool_message, 'the tool result goes back to the model'
  end

  test 'a write tool only proposes; approving runs it as the approver and posts a notice' do
    script_model({ tool: 'create_task', arguments: { title: 'Recount the tea shelf', priority: 'high' } },
      { text: 'I proposed the task; approve it below.' })
    reply = ask('@rupert make a task to recount the tea shelf')

    assert_no_difference -> { Projects::Task.count } do
      TeamChat::Agent.new(reply, config: team_chat_config).run
    end
    action = reply.reload.actions_list.first
    assert_equal 'proposed', action['status']
    assert_equal 'Create task “Recount the tea shelf” (high)', action['summary']

    assert_difference -> { Projects::Task.count }, 1 do
      TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: true)
    end
    assert_equal 'done', reply.reload.actions_list.first['status']
    notice = @room.messages.where(author_kind: 'system').last
    assert_match(/approved: Created task #\d+/, notice.body)
    assert_raises(TeamChat::Actions::Denied) { TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: true) }
  end

  test 'a dismissed proposal runs nothing' do
    script_model({ tool: 'create_task', arguments: { title: 'Nope' } }, { text: 'Proposed.' })
    reply = ask('@rupert task please')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    action = reply.reload.actions_list.first
    assert_no_difference -> { Projects::Task.count } do
      TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: false)
    end
    assert_equal 'dismissed', reply.reload.actions_list.first['status']
  end

  test 'the thread is the context when the question is asked in a thread' do
    root = @room.messages.create!(user: @user, body: 'Inventory count tonight?')
    @room.messages.create!(user: @user, body: 'Something unrelated at top level')
    requests = script_model({ text: 'Yes.' })
    reply = ask('@rupert is that on the schedule?', parent_id: root.id)
    assert_equal root.id, reply.parent_id

    TeamChat::Agent.new(reply, config: team_chat_config).run
    contents = requests.first['messages'].drop(1).pluck('content').join("\n")
    assert_includes contents, 'Inventory count tonight?'
    assert_not_includes contents, 'Something unrelated'
  end

  test 'a refused credential becomes a friendly failure' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 401, body: { error: { message: 'bad key' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    reply = ask('@rupert hi')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    reply.reload
    assert_equal 'failed', reply.status
    assert_match(/credential was refused/, reply.body)
  end

  test 'opencode go sends the session header and the stored opencode key' do
    Dir.mktmpdir do |dir|
      auth = File.join(dir, 'auth.json')
      File.write(auth, JSON.generate('opencode-go' => { 'type' => 'api', 'key' => 'go-key' }))
      config = TeamChat::ModelConfig.new({}, auth_file: auth)
      assert_equal 'opencode_go', config.engine
      assert config.configured?
      stub = stub_request(:post, "#{TeamChat::ModelConfig::OPENCODE_GO_BASE}/chat/completions")
             .with(headers: { 'Authorization' => 'Bearer go-key', 'X-Opencode-Session' => "rupert-room-#{@room.id}" })
             .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Hi!'))
      reply = ask('@rupert hi')
      TeamChat::Agent.new(reply, config: config).run
      assert_requested stub
      assert_equal 'Hi!', reply.reload.body
    end
  end

  test 'model config picks ollama when only a local model is set, and the CLI otherwise' do
    Dir.mktmpdir do |dir|
      none = File.join(dir, 'missing.json')
      local = TeamChat::ModelConfig.new({ 'OLLAMA_URL' => 'http://127.0.0.1:11434', 'ASK_RUPERT_LOCAL_MODEL' => 'qwen3.5:4b' }, auth_file: none)
      assert_equal 'ollama', local.engine
      assert_equal 'http://127.0.0.1:11434/v1', local.api_base
      assert local.local?
      assert_equal 'opencode_cli', TeamChat::ModelConfig.new({}, auth_file: none).engine
    end
  end
end
