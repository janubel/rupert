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
    assert_equal %w[qwen lfm bonsai gemma], TeamChat::LocalAgents.all.map(&:handle)
    ENV['RUPERT_LOCAL_LLM_URL'] = nil
    assert_empty TeamChat::LocalAgents.all
    assert_empty post('@gemma hello').replies
  end

  test 'each mentioned local agent gets its own pending reply, alongside @rupert' do
    result = post('@rupert and @gemma and @lfm: how were sales yesterday?')
    assert_equal [nil, 'gemma', 'lfm'], result.replies.map { |reply| reply.meta['agent'] }
    gemma = result.replies.second
    assert gemma.pending?
    assert_equal 'Gemma 4', gemma.author_name
    assert_equal 'Loading Gemma 4', gemma.activity
    assert_equal 'gemma', gemma.as_payload(viewer: @user)[:author][:agent]
  end

  test 'a local agent answers through the gateway with its own model and persona, and sees @rupert as another voice' do
    @room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Earlier answer from Rupert.', meta: { 'asked_by' => @user.id })
    requests = script_model({ text: 'Hi, I am Gemma.' })
    reply = post('@gemma say hi').replies.first

    TeamChat::Agent.new(reply).run
    reply.reload

    assert_equal 'done', reply.status
    assert_equal 'Hi, I am Gemma.', reply.body
    assert_equal 'gemma-4-e4b', requests.first['model']
    assert_equal 'local_gateway', reply.meta['engine']
    assert_includes requests.first['messages'].first['content'], 'You are Gemma 4 (@gemma)'
    roles = requests.first['messages'].map { |message| [message['role'], message['content'].to_s.first(12)] }
    assert_includes roles, ['user', 'Rupert: Earl'], "@rupert's reply is quoted as another voice"
  end

  test 'a gateway that is down fails the reply plainly without falling back to the cloud model' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 503, body: { error: { message: 'timed out loading gemma-4-e4b' } }.to_json)
    reply = post('@gemma hi').replies.first
    TeamChat::Agent.new(reply).run
    reply.reload
    assert_equal 'failed', reply.status
    assert_equal 'local_gateway', reply.meta['engine']
  end
end
