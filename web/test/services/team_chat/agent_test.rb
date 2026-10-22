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
    run = AiAgentRun.where(agent: 'team_chat').last
    assert_equal ['test-model', 'ok'], [run.model, run.outcome]
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

  test 'assigning a task from chat proposes update_task for the right person and mentions them when approved' do
    jan = User.create!(tenant: @tenant, email: 'jan.tester@example.com', name: 'Jan Tester', role: @user.role, password: 'password123')
    task = Projects::Task.create!(title: 'Count the tea shelf', priority: 'medium')
    script_model({ tool: 'update_task', arguments: { task_id: task.id, assignee: 'Jan', due_on: '2026-10-30', priority: 'high' } },
      { text: 'Proposed: give it to Jan for Friday.' })
    reply = ask('@rupert assign the tea shelf count to Jan, due Friday, high priority')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    action = reply.reload.actions_list.first
    assert_equal 'proposed', action['status']
    assert_equal "Task ##{task.id} “Count the tea shelf”: assign to Jan Tester, priority high, due 2026-10-30", action['summary']
    assert_equal 'jan.tester@example.com', action.dig('arguments', 'assignee')
    assert_nil task.reload.assignee_id

    TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: true)
    task.reload
    assert_equal [jan.id.to_s, 'high', Date.new(2026, 10, 30)], [task.assignee_id, task.priority, task.due_on]
    notice = @room.messages.where(author_kind: 'system').last
    assert_match(/approved: Updated task ##{task.id}/, notice.body)
    assert_equal [jan.id], notice.mention_ids
  end

  test 'a name that matches two people is sent back to the model to ask which one' do
    2.times { |index| User.create!(tenant: @tenant, email: "sam#{index}@example.com", name: 'Sam Twin', role: @user.role, password: 'password123') }
    requests = script_model({ tool: 'create_task', arguments: { title: 'Restock', assignee: 'Sam Twin' } }, { text: 'Which Sam?' })
    reply = ask('@rupert make a restock task for Sam Twin')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_empty reply.reload.actions_list
    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert_match(/matches 2 people: Sam Twin \(sam0@…\), Sam Twin \(sam1@…\)/, tool_message['content'])
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

  test 'links to pages Rupert does not have become plain text' do
    script_model({ text: 'See [Alerts](/inventory/alerts) and [Timesheets](/people/timesheets) or [Home](/).' })
    reply = ask('@rupert where?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'See Alerts and [Timesheets](/people/timesheets) or [Home](/).', reply.reload.body
  end

  test 'local_gateway sends @rupert to the rupert-llm gateway with long timeouts and no key' do
    config = TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'local_gateway', 'RUPERT_CHAT_MODEL' => 'qwen3.5-4b',
                                         'RUPERT_LOCAL_LLM_URL' => 'http://10.0.0.7:8080/v1/' })
    assert config.configured?
    assert config.local?
    assert_equal 'http://10.0.0.7:8080/v1', config.api_base
    assert_equal 'qwen3.5-4b on this server', config.label
    assert_match(/nothing leaves it/, config.disclosure)
    stub = stub_request(:post, 'http://10.0.0.7:8080/v1/chat/completions')
           .with { |request| JSON.parse(request.body)['model'] == 'qwen3.5-4b' && JSON.parse(request.body)['messages'].first['role'] == 'system' }
           .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Local hello.'))
    reply = ask('@rupert hi')
    assert_no_difference -> { AiAgentRun.count } do
      TeamChat::Agent.new(reply, config: config).run
    end
    assert_requested stub
    assert_equal 'Local hello.', reply.reload.body
  end
end
