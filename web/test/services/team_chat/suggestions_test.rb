# frozen_string_literal: true

require 'test_helper'

# The suggestion bubbles above the chat box.
class TeamChatSuggestionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:regular_user)
    Current.tenant = tenants(:default_tenant)
    Current.user = @user
    @direct = TeamChat::Room.direct_for(@user)
  end

  teardown { Current.reset }

  def at(text) = Time.zone.parse(text)

  test 'questions for the time of day come first and the row stays the same all day' do
    morning = TeamChat::Suggestions.for(room: @direct, user: @user, now: at('2026-10-22 09:00'))
    assert_equal 6, morning.size
    assert_equal ['How did yesterday go?', 'What should I look at first today?', 'Any orders waiting to ship?'], morning.first(3).pluck(:label)
    assert_equal morning, TeamChat::Suggestions.for(room: @direct, user: @user, now: at('2026-10-22 10:30'))
    evening = TeamChat::Suggestions.for(room: @direct, user: @user, now: at('2026-10-22 18:00'))
    assert_equal 'How did today go?', evening.first[:label]
  end

  test 'Mondays and the start of a month add their own questions' do
    labels = TeamChat::Suggestions.for(room: @direct, user: @user, now: at('2026-11-02 12:00')).pluck(:label) # a Monday, the 2nd
    assert_includes labels, 'How did last week compare with the week before?'
    assert_includes labels, 'Is last month closed in the books?'
  end

  test 'in a channel where bots answer only when named, the bubble asks @rupert' do
    channel = TeamChat::Room.create!(name: 'floor', assistant_mode: 'mentions', created_by: @user)
    first = TeamChat::Suggestions.for(room: channel, user: @user, now: at('2026-10-22 09:00')).first
    assert_equal 'How did yesterday go?', first[:label]
    assert_equal '@rupert How did yesterday go?', first[:text]
    assert_equal 'How did yesterday go?', TeamChat::Suggestions.for(room: @direct, user: @user, now: at('2026-10-22 09:00')).first[:text]
  end

  test 'no bubbles where no bot answers' do
    channel = TeamChat::Room.create!(name: 'quiet', assistant_mode: 'off', created_by: @user)
    assert_empty TeamChat::Suggestions.for(room: channel, user: @user)
    other = User.where(tenant_id: @user.tenant_id).where.not(id: @user.id).first
    assert_empty TeamChat::Suggestions.for(room: TeamChat::Room.dm_between(@user, other), user: @user) if other
  end
end
