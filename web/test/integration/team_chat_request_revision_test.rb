# frozen_string_literal: true

require 'test_helper'

class TeamChatRequestRevisionHttpTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    Current.tenant = @tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
    @room = TeamChat::Room.direct_for(@user)
    @post = TeamChat::Post.call(room: @room, user: @user, body: '@rupert explain the original workflow')
  end
  teardown { Current.reset }

  test 'the edit response updates the original stopped reply and replacement immediately' do
    patch team_chat_message_path(@room.slug, @post.message.id), params: { body: '@rupert where is inventory?' }, as: :json
    assert_response :success
    messages = response.parsed_body['messages']
    assert_equal 3, messages.size
    assert_equal [@post.message.id, @post.reply.id], messages.first(2).pluck('id')
    assert_equal 'failed', messages[1]['status']
    assert_equal 'pending', messages[2]['status']
    assert_equal 'cancelled', @post.reply.run.reload.state
    assert_equal 1, TeamChat::Run.find_by!(message_id: messages[2]['id']).request_context['request_revision']
  end

  test 'deletion updates the stopped reply without starting another answer' do
    assert_no_difference -> { TeamChat::Run.count } do
      delete team_chat_message_path(@room.slug, @post.message.id), as: :json
    end
    assert_response :success
    assert response.parsed_body['messages'].first['deleted']
    assert_equal 'failed', response.parsed_body['messages'].last['status']
    assert_equal 'cancelled', @post.reply.run.reload.state
  end

  test 'a shared edit response never inserts private handoff messages into the shared feed' do
    channel = TeamChat::Room.ensure_defaults!(@user)
    post = TeamChat::Post.call(room: channel, user: @user, body: '@rupert explain my task workflow')
    TeamChat::Agent.new(post.reply).run
    child = @room.messages.where(author_kind: 'assistant').order(:id).last
    patch team_chat_message_path(channel.slug, post.message.id), params: { body: '@rupert explain the revised workflow' }, as: :json
    assert_response :success
    ids = response.parsed_body['messages'].pluck('id')
    assert_not_includes ids, child.id
    assert TeamChat::Message.where(id: ids).all? { |message| message.room_id == channel.id }
    assert_equal 'cancelled', child.run.reload.state
  end

  test 'oversized input returns a useful error and leaves the original answer active' do
    patch team_chat_message_path(@room.slug, @post.message.id), params: { body: 'x' * (TeamChat::Message::BODY_MAX + 1) }, as: :json
    assert_response :unprocessable_entity
    assert_match(/long/i, response.parsed_body['error'])
    assert_equal 'queued', @post.reply.run.reload.state
    assert_equal 0, @post.message.reload.request_revision
  end

  test 'an edit cannot restart a different persons request' do
    other = User.create!(tenant: @tenant, email: 'revision-owner@example.com', role: 'admin', password: 'password123')
    channel = TeamChat::Room.ensure_defaults!(@user)
    post = TeamChat::Post.call(room: channel, user: other, body: '@rupert explain my task workflow')
    assert_no_difference -> { TeamChat::Run.count } do
      patch team_chat_message_path(channel.slug, post.message.id), params: { body: '@rupert where is inventory?' }, as: :json
    end
    assert_response :forbidden
    assert_equal 'queued', post.reply.run.reload.state
  end
end
