# frozen_string_literal: true

require 'test_helper'

class AskRupertBuzzChannelsTest < ActiveSupport::TestCase
  AGENT = 'a' * 64
  PERSON = 'b' * 64
  OTHER = 'c' * 64
  DM = '11111111-1111-4111-8111-111111111111'
  ROOM = '22222222-2222-4222-8222-222222222222'

  setup { @channels = AskRupert::BuzzChannels.new(AGENT) }

  def member_list(id, type, members)
    { 'kind' => 39_002, 'tags' => [['d', id], ['t', type], ['P', PERSON]] + members.map { |key| ['p', key] } }
  end

  test 'a message channel with the agent and exactly the sender is a direct message' do
    assert @channels.observe(member_list(DM, 'dm', [AGENT, PERSON]))
    assert_equal :dm, @channels.kind_for(DM, PERSON)
    assert_equal :room, @channels.kind_for(DM, OTHER), 'someone who is not in it is never treated as private'
  end

  test 'a group message, a stream and anything unknown are rooms' do
    @channels.observe(member_list(DM, 'dm', [AGENT, PERSON, OTHER]))
    @channels.observe(member_list(ROOM, 'stream', [AGENT, PERSON]))
    assert_equal :room, @channels.kind_for(DM, PERSON)
    assert_equal :room, @channels.kind_for(ROOM, PERSON)
    assert_equal :room, @channels.kind_for('33333333-3333-4333-8333-333333333333', PERSON)
    assert_equal :room, @channels.kind_for(nil, PERSON)
  end

  test 'a channel the agent is not a member of is ignored, and one it leaves is forgotten' do
    assert_not @channels.observe(member_list(ROOM, 'stream', [PERSON]))
    assert_empty @channels.ids
    @channels.observe(member_list(ROOM, 'stream', [AGENT, PERSON]))
    assert_equal [ROOM], @channels.ids
    assert @channels.observe(member_list(ROOM, 'stream', [PERSON])), 'the list changed'
    assert_empty @channels.ids
  end

  test 'a bad channel id is ignored' do
    assert_not @channels.observe(member_list('not-a-uuid', 'dm', [AGENT, PERSON]))
    assert_empty @channels.ids
  end

  test 'only the first sighting of a channel asks for a fresh list, so replays cannot loop' do
    notice = { 'kind' => 44_100, 'tags' => [['p', AGENT], ['h', ROOM], ['t', 'stream']] }
    assert @channels.observe(notice)
    assert_not @channels.observe(notice)
    assert_not @channels.observe({ 'kind' => 44_100, 'tags' => [['p', OTHER], ['h', DM]] }), 'a notice for someone else'
  end

  test 'a removal notice forgets the channel' do
    @channels.observe(member_list(ROOM, 'stream', [AGENT, PERSON]))
    assert @channels.observe({ 'kind' => 44_101, 'tags' => [['p', AGENT], ['h', ROOM]] })
    assert_empty @channels.ids
  end
end
