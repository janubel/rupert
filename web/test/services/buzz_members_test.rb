# frozen_string_literal: true

require 'test_helper'

class BuzzMembersTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    EnvStore.set('BUZZ_MEMBER_NAMES', nil)
    Current.reset
  end

  test 'configured names become a stable roster and initials' do
    derek = 'a' * 64
    jan = 'b' * 64
    EnvStore.set('BUZZ_MEMBER_NAMES', { derek => 'Derek Ubel', jan => 'Jan' }.to_json)
    channel = BuzzChannels::Channel.new(id: 'channel', name: 'rupert', about: '', members: 2, pubkeys: [derek, jan])

    roster = BuzzMembers.roster(channel)

    assert_equal [derek, jan], roster.map(&:pubkey)
    assert_equal ['Derek Ubel', 'Jan'], roster.map(&:name)
    assert_equal ['DU', 'J'], roster.map(&:initials)
    assert_equal 0, BuzzMembers.extra_count(channel)
    assert_match(/\Ahsl\(\d+ 38% 48%\)\z/, roster.first.color)
  end

  test 'unnamed members fall back to a neutral label and the agent is not listed' do
    channel = BuzzChannels::Channel.new(id: 'channel', name: 'rupert', about: '', members: 2, pubkeys: ['c' * 64])

    roster = BuzzMembers.roster(channel)

    assert_equal ['Teammate'], roster.map(&:name)
    assert_equal ['T'], roster.map(&:initials)
  end
end
