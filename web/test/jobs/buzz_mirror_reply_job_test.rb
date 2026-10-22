# frozen_string_literal: true

require 'test_helper'
require_relative '../support/buzz_chat_helper'

# The WebUI posts as the agent, so the real Buzz agent ignores the message. This
# job is the WebUI's own answer path for an @rupert mention.
class BuzzMirrorReplyJobTest < ActiveJob::TestCase
  include BuzzChatHelper

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = users(:regular_user)
    start_buzz_relay
  end

  teardown do
    stop_buzz_relay
  end

  test 'answers a mention as the agent and pulls the answer into the channel' do
    answer = AskRupert::HelpBrain::Answer.new(text: 'Open Day close and follow the next unfinished day.', ok: true)
    brain = Object.new
    brain.define_singleton_method(:answer) { |_question| answer }
    config = Object.new
    config.define_singleton_method(:enabled?) { true }

    AskRupert::Config.stub(:current, config) do
      AskRupert::HelpBrain.stub(:new, brain) do
        BuzzMirrorReplyJob.perform_now(@tenant.id, @user.id, BuzzChatHelper::CHANNEL, 'hello @rupert', 'a' * 64)
      end
    end

    Current.tenant = @tenant
    published = @relay.published.last
    assert_equal BuzzAgent.public_key_hex, published['pubkey']
    assert_equal 'Open Day close and follow the next unfinished day.', published['content']
    assert_includes published['tags'], ['e', 'a' * 64]
    assert BuzzMessage.exists?(event_id: published['id']), 'the reply is in the channel copy'
  end

  test 'stays quiet when Ask Rupert is switched off' do
    config = Object.new
    config.define_singleton_method(:enabled?) { false }

    AskRupert::Config.stub(:current, config) do
      BuzzMirrorReplyJob.perform_now(@tenant.id, @user.id, BuzzChatHelper::CHANNEL, 'hello @rupert', 'a' * 64)
    end

    assert_empty @relay.published
  end
end
