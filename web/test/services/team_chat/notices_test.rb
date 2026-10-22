# frozen_string_literal: true

require 'test_helper'

class TeamChatNoticesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'stays quiet until team chat has been opened in the workspace' do
    assert_not TeamChat::Notices.configured?
    assert_equal [false, 'team chat is not set up yet'], TeamChat::Notices.notify('Sync complete')
    assert_equal 0, TeamChat::Message.count
  end

  test 'posts into #announcements, creating it the first time' do
    TeamChat::Room.ensure_defaults!(users(:regular_user))
    assert_equal [true, 'posted'], TeamChat::Notices.notify('Sync complete · square')
    room = TeamChat::Room.find_by(slug: 'announcements')
    assert_equal 'mentions', room.assistant_mode
    notice = room.messages.last
    assert notice.system?
    assert_equal 'Sync complete · square', notice.body
    assert_equal 'Rupert', notice.author_name

    TeamChat::Notices.notify('Second')
    assert_equal 1, TeamChat::Room.where(slug: 'announcements').count
  end

  test 'the job posts for the given tenant' do
    TeamChat::Room.ensure_defaults!(users(:regular_user))
    Current.reset
    TeamChat::NoticeJob.perform_now(@tenant.id, 'Manual count submitted for approval')
    Current.tenant = @tenant
    assert_equal 'Manual count submitted for approval', TeamChat::Room.find_by(slug: 'announcements').messages.last.body
  end
end
