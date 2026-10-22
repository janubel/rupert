# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatLocalAgentsTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @room = TeamChat::Room.ensure_defaults!(@user)
    @previous = ENV['RUPERT_LOCAL_LLM_URL']
    ENV['RUPERT_LOCAL_LLM_URL'] = LLM_BASE
  end

  teardown do
    ENV['RUPERT_LOCAL_LLM_URL'] = @previous
    Current.reset
  end

  def post(text) = TeamChat::Post.call(room: @room, user: @user, body: text)

  test 'local agents exist only when the gateway is configured' do
    assert_equal %w[liquid qwen gemma], TeamChat::LocalAgents.all.map(&:handle)
    ENV['RUPERT_LOCAL_LLM_URL'] = nil
    assert_empty TeamChat::LocalAgents.all
    assert_empty post('@qwen hello').replies
  end

  test 'bots answer to the names people actually type: @gemma4, @Gemma-4, @qwen3.5, @lfm' do
    assert_equal ['gemma'], post('@gemma4 how are sales today').replies.map { |reply| reply.meta['agent'] }
    assert_equal ['gemma'], post('@Gemma-4 hi').replies.map { |reply| reply.meta['agent'] }
    assert_equal ['qwen'], post('@qwen3.5 hi').replies.map { |reply| reply.meta['agent'] }
    assert_equal ['liquid'], post('hey @lfm, hi').replies.map { |reply| reply.meta['agent'] }
    assert_empty post('@gemma-e2b and @gemmas and email@gemma.dev').replies
  end

  test 'each mentioned local agent gets its own pending reply, alongside @rupert' do
    result = post('@rupert and @qwen and @liquid: how were sales yesterday?')
    assert_equal [nil, 'qwen', 'liquid'], result.replies.map { |reply| reply.meta['agent'] }
    qwen_reply = result.replies.second
    assert qwen_reply.pending?
    assert_equal 'Qwen', qwen_reply.author_name
    assert_equal 'Loading Qwen', qwen_reply.activity
    assert_equal 'qwen', qwen_reply.as_payload(viewer: @user)[:author][:agent]
  end

  test 'a local agent answers through the gateway with its own model and persona, and sees @rupert as another voice' do
    @room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Earlier answer from Rupert.', meta: { 'asked_by' => @user.id })
    requests = script_model({ text: 'Hi, I am Qwen.' })
    reply = post('@qwen say hi').replies.first

    TeamChat::Agent.new(reply).run
    reply.reload

    assert_equal 'done', reply.status
    assert_equal 'Hi, I am Qwen.', reply.body
    assert_equal 'qwen3.6-35b-a3b', requests.first['model']
    assert_equal 'local_gateway', reply.meta['engine']
    assert_includes requests.first['messages'].first['content'], 'You are Qwen (@qwen)'
    users = requests.first['messages'].select { |message| message['role'] == 'user' }.map { |message| message['content'].to_s }
    assert(users.any? { |content| content.include?("\nRupert: Earlier answer from Rupert.") }, "@rupert's reply is quoted as another voice")
  end

  test 'a reply that waited for the model to load says how long the load took' do
    @gateway_last_load = { model: 'qwen3.6-35b-a3b', seconds: 17.5, finished_at: Time.now.to_f, reason: 'request' }
    script_model({ text: 'Loaded and ready.' })
    reply = post('@qwen hello').replies.first
    TeamChat::Agent.new(reply).run
    reply.reload

    assert_equal 17_500, reply.meta['load_ms']
    assert_equal 17.5, reply.answer_timing[:load_seconds]
  end

  test 'a load for another model, an older load or the keep-loaded warm-up is not counted' do
    [{ model: 'lfm2.5-8b-a1b', finished_at: Time.now.to_f, reason: 'request' },
     { model: 'qwen3.6-35b-a3b', finished_at: Time.now.to_f - 600, reason: 'request' },
     { model: 'qwen3.6-35b-a3b', finished_at: Time.now.to_f, reason: 'keep_loaded' }].each do |load|
      @gateway_last_load = load.merge(seconds: 17.5)
      script_model({ text: 'Ready.' })
      reply = post('@qwen hello').replies.first
      TeamChat::Agent.new(reply).run

      assert_nil reply.reload.meta['load_ms'], load.inspect
      assert_not reply.answer_timing.key?(:load_seconds)
    end
  end

  test 'a local bot gets only the tools for what the question is about, and the matching data guide card' do
    requests = script_model({ text: 'Two orders.' })
    reply = post('@qwen how much sales tax did we collect last month?').replies.first
    TeamChat::Agent.new(reply).run

    tools = requests.first['tools'].map { |tool| tool.dig('function', 'name') }
    assert_includes tools, 'sales_tax_report'
    assert_includes tools, 'where_is'
    assert_not_includes tools, 'list_alerts'
    assert_not_includes tools, 'create_task'
    assert_operator tools.size, :<, 12
    question = requests.first['messages'].last['content']
    assert_includes question, 'About this question'
    assert_match(/Sales tax \(tools: sales_tax_report\): .*never add sources together/, question)
    assert_not_includes requests.first['messages'].first['content'], 'Sales tax (tools', 'per-question notes stay out of the cached instructions'
    last_month = Date.current.prev_month
    assert_includes question, "last month = #{last_month.beginning_of_month.iso8601} to #{last_month.end_of_month.iso8601}"
    assert_equal %w[tax sales], reply.reload.meta['topics']
  end

  test 'a question with no topic keeps every tool' do
    requests = script_model({ text: 'Hi!' })
    reply = post('@qwen hello there').replies.first
    TeamChat::Agent.new(reply).run
    assert_includes requests.first['tools'].map { |tool| tool.dig('function', 'name') }, 'list_alerts'
    assert_not_includes requests.first['messages'].last['content'], 'About this question'
    assert_nil reply.reload.meta['topics']
  end

  test 'the instructions stay the same from question to question so the model server can reuse them' do
    requests = script_model({ text: 'One.' }, { text: 'Two.' })
    TeamChat::Agent.new(post('@qwen how were sales yesterday?').replies.first).run
    other = TeamChat::Room.create!(name: 'inventory', slug: 'inventory', kind: 'channel', created_by: @user)
    reply = TeamChat::Post.call(room: other, user: @user, body: '@qwen any low stock?').replies.first
    TeamChat::Agent.new(reply).run

    assert_equal requests.first['messages'].first['content'], requests.last['messages'].first['content']
    assert_match(/\AContext for this reply \(from Rupert\):\nYou are in the #inventory room/, requests.last['messages'].last['content'])
    assert_match(/Today is \w+day #{Date.current.iso8601}/, requests.last['messages'].last['content'])
  end

  test 'with RUPERT_LOCAL_TOOLS=all a local bot keeps every tool and is told which to use' do
    ENV['RUPERT_LOCAL_TOOLS'] = 'all'
    requests = script_model({ text: 'Tax.' })
    TeamChat::Agent.new(post('@qwen how much sales tax did we collect last month?').replies.first).run
    assert_includes requests.first['tools'].map { |tool| tool.dig('function', 'name') }, 'list_alerts'
    assert_match(/Use these tools for this question: sales_tax_report, .*sales_summary/, requests.first['messages'].last['content'])
  ensure
    ENV.delete('RUPERT_LOCAL_TOOLS')
  end

  test 'a gateway that is down fails the reply plainly without falling back to the cloud model' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 503, body: { error: { message: 'timed out loading qwen3.5-4b' } }.to_json)
    reply = post('@qwen hi').replies.first
    TeamChat::Agent.new(reply).run
    reply.reload
    assert_equal 'failed', reply.status
    assert_equal 'local_gateway', reply.meta['engine']
  end
end
