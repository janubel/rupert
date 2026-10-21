# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

# The agent's decisions about which channel a message is in and who answers it.
# The relay, the model and publishing are stubbed.
class OpencodeChatAgentTest < ActiveSupport::TestCase
  include AskRupertHelper

  AGENT = 'a' * 64
  TEAM = '11111111-1111-4111-8111-111111111111'
  DM = '22222222-2222-4222-8222-222222222222'
  ROOM = '33333333-3333-4333-8333-333333333333'

  setup do
    @user = person('admin')
    @tenant = @user.tenant
    @key = SecureRandom.hex(32)
    AskRupert::Config.update!('buzz_enabled' => '1')
    @agent = OpencodeChatAgent.allocate
    @agent.instance_variable_set(:@tenant, @tenant)
    @agent.instance_variable_set(:@pubkey, AGENT)
    @agent.instance_variable_set(:@channel, TEAM)
    @agent.instance_variable_set(:@relay, 'wss://buzz.example.com')
    @agent.instance_variable_set(:@contexts, Hash.new { |hash, key| hash[key] = [] })
    @agent.instance_variable_set(:@channels, AskRupert::BuzzChannels.new(AGENT))
    @agent.instance_variable_set(:@ask_rupert_on, true)
    @published = []
    @agent.stubs(:publish_reply).with { |text, _event, channel| @published << [text, channel] }
    @legacy = []
    @agent.stubs(:generate_reply).with { |content, **| @legacy << content }.returns('legacy answer')
    @provider = ScriptedProvider.new(Array.new(5, 'Open [Sync](/syncs).'))
    AskRupert::Providers.stubs(:for_turn).returns([@provider])
  end

  teardown { Current.reset }

  def link!
    _, code = BuzzIdentity.issue_code!(@user)
    BuzzIdentity.claim(code: code, pubkey: @key).identity.confirm!
  end

  def member_list(id, type, members)
    { 'id' => SecureRandom.hex(32), 'kind' => 39_002, 'tags' => [['d', id], ['t', type]] + members.map { |key| ['p', key] } }
  end

  def chat_event(text, channel, key: @key, tags: [])
    { 'id' => SecureRandom.hex(32), 'kind' => 9, 'pubkey' => key, 'content' => text, 'tags' => [['h', channel]] + tags }
  end

  def learn(id, type, members)
    @agent.stubs(:resubscribe)
    @agent.process_event(member_list(id, type, members))
  end

  test 'a linked person in a direct message is answered by Ask Rupert in that channel only' do
    link!
    learn(DM, 'dm', [AGENT, @key])
    @agent.process_event(chat_event('Where do I find sync history?', DM))
    assert_equal 1, @published.size
    assert_equal DM, @published.first.last
    assert_includes @published.first.first, '/syncs'
    assert_empty @legacy, 'the free-form team prompt and its operations snapshot are never used in a direct message'
  end

  test 'an unlinked person in a direct message gets the hint, never the operations snapshot' do
    learn(DM, 'dm', [AGENT, @key])
    @agent.process_event(chat_event('How is stock?', DM))
    assert_match(/linked/, @published.first.first)
    assert_equal DM, @published.first.last
    assert_empty @legacy
    assert_empty @provider.calls
  end

  test 'a link code sent in a direct message links, and in the team channel it is refused' do
    learn(DM, 'dm', [AGENT, @key])
    _, code = BuzzIdentity.issue_code!(@user)
    @agent.process_event(chat_event("link #{code}", DM))
    assert_equal 'pending', BuzzIdentity.find_by(pubkey: @key).status
    _, second = BuzzIdentity.issue_code!(@user)
    @agent.process_event(chat_event("link #{second}", TEAM, key: SecureRandom.hex(32)))
    assert_equal TEAM, @published.last.last
    assert_match(/direct message/, @published.last.first)
    assert_equal :invalid, BuzzIdentity.claim(code: second, pubkey: SecureRandom.hex(32)).status
  end

  test 'in another channel it answers only when mentioned, and only linked people' do
    link!
    learn(ROOM, 'stream', [AGENT, @key, 'c' * 64])
    @agent.process_event(chat_event('lunch?', ROOM))
    assert_empty @published
    @agent.process_event(chat_event('@rupert where is sync?', ROOM))
    assert_equal ROOM, @published.last.last
    assert_empty @legacy
    @agent.process_event(chat_event('@rupert what is stock like?', ROOM, key: 'd' * 64))
    assert_match(/linked/, @published.last.first)
    assert_empty @legacy
  end

  test 'a group message is a room even if it is a direct message type' do
    link!
    learn(DM, 'dm', [AGENT, @key, 'c' * 64])
    @agent.process_event(chat_event('@rupert where is sync?', DM))
    assert_not_includes @provider.calls.first[:system], 'private Buzz message'
    assert_includes @provider.calls.first[:system], 'Other people can read your reply'
  end

  test 'the team channel carries on as before for everyone' do
    link!
    @agent.process_event(chat_event('@rupert hello there', TEAM))
    assert_equal ['@rupert hello there'], @legacy
    assert_equal [['legacy answer', TEAM]], @published
    assert_empty @provider.calls
  end

  test 'a direct message never reaches the team channel prompt' do
    link!
    learn(DM, 'dm', [AGENT, @key])
    @agent.process_event(chat_event('my private question about payroll', DM))
    @agent.process_event(chat_event('@rupert what is up', TEAM, key: 'e' * 64))
    team_context = @agent.instance_variable_get(:@contexts)[TEAM].join("\n")
    assert_not_includes team_context, 'payroll'
    assert_includes @agent.instance_variable_get(:@contexts)[DM].join("\n"), 'payroll'
  end

  test 'with the switch off nothing changes: the team channel is answered the old way' do
    @agent.instance_variable_set(:@ask_rupert_on, false)
    @agent.process_event(chat_event('@rupert hi there', TEAM))
    assert_equal [['legacy answer', TEAM]], @published
  end

  test 'if the switch is turned off while it runs, other channels are ignored' do
    link!
    learn(ROOM, 'stream', [AGENT, @key])
    AskRupert::Config.update!('buzz_enabled' => '0')
    @agent.process_event(chat_event('@rupert where is sync?', ROOM))
    assert_empty @published
    assert_empty @legacy
  end

  test 'learning a new channel subscribes again including it, and a repeat does not' do
    @agent.expects(:resubscribe).once
    @agent.process_event(member_list(ROOM, 'stream', [AGENT, @key]))
    @agent.process_event(member_list(ROOM, 'stream', [AGENT, @key]))
    ids = @agent.filters(0).first[:"#h"]
    assert_equal [TEAM, ROOM], ids
    assert_includes @agent.filters(0).map { |filter| filter[:kinds] }, AskRupert::BuzzChannels::GROUP_KINDS
  end

  test 'with the switch off only the team channel is subscribed' do
    @agent.instance_variable_set(:@ask_rupert_on, false)
    assert_equal [{ kinds: [9], "#h": [TEAM], since: 5 }, { kinds: [1], "#p": [AGENT], since: 5 }], @agent.filters(5)
  end

  test 'an event from the agent itself is ignored' do
    link!
    learn(DM, 'dm', [AGENT, @key])
    @agent.process_event(chat_event('hello', DM, key: AGENT))
    assert_empty @published
  end
end
