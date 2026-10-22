# frozen_string_literal: true

require 'test_helper'
require_relative '../support/buzz_chat_helper'

class BuzzChatTest < ActiveSupport::TestCase
  include BuzzChatHelper

  setup do
    start_buzz_relay
    @user = users(:regular_user)
    @t0 = Time.now.to_i - 3600
  end

  teardown { stop_buzz_relay }

  def seed(count, key: @alice, from: @t0)
    count.times { |i| @relay.add(@relay.message(key, "message #{i}", at: from + i)) }
  end

  test 'sync stores channel messages and names their authors' do
    @relay.add(@relay.profile(@alice, name: 'alice', display_name: 'Alice A'))
    @relay.add(@relay.message(@alice, 'hello team', at: @t0))
    @relay.add(@relay.message(@bob, 'second', at: @t0 + 5))

    assert_equal 2, BuzzChat.sync!, BuzzChat.status[:error]
    page = BuzzChat.page
    assert_equal ['hello team', 'second'], page[:messages].map { |m| m[:text] }
    assert_equal 'Alice A', page[:messages][0][:author]
    assert page[:messages][0][:named]
    assert_match(/\Anpub1\w{7}…\w{4}\z/, page[:messages][1][:author], 'unknown people fall back to a short npub')
    refute page[:messages][1][:named]
    assert_not page[:has_more]
  end

  test 'a second sync only adds what is new and keeps one copy of each message' do
    seed(3)
    assert_equal 3, BuzzChat.sync!
    @relay.add(@relay.message(@bob, 'late', at: @t0 + 100))
    assert_equal 1, BuzzChat.sync!
    assert_equal 4, BuzzMessage.count
    assert_equal 0, BuzzChat.sync!
  end

  test 'events that are forged, off-channel or the wrong kind are ignored' do
    good = @relay.message(@alice, 'real', at: @t0)
    forged = @relay.message(@alice, 'forged', at: @t0 + 1).merge('content' => 'tampered')
    other_channel = @relay.message(@alice, 'elsewhere', at: @t0 + 2, channel: 'someone-elses-channel')
    wrong_kind = FakeBuzzRelay.signed(@alice, kind: 1, content: 'note', tags: [['h', CHANNEL]], created_at: @t0 + 3)
    [good, forged, other_channel, wrong_kind].each { |e| @relay.add(e) }

    BuzzChat.sync!
    assert_equal ['real'], BuzzMessage.pluck(:content)
  end

  test 'text is cleaned and capped, and private keys never reach the copy' do
    nsec = 'nsec1' + ('q' * 58)
    @relay.add(@relay.message(@alice, "x\u0007y #{nsec} " + ('z' * 5000), at: @t0))
    BuzzChat.sync!
    content = BuzzMessage.first.content
    assert_equal BuzzMessage::CONTENT_MAX, content.length
    assert_includes content, 'xy [private key removed]'
    refute_includes content, nsec
  end

  test 'the agent is labelled and a person posting through Rupert is named' do
    agent = agent_key
    @relay.add(@relay.message(agent, 'Sync finished.', at: @t0))
    @relay.add(@relay.message(agent, 'Sam via Rupert: hi all', at: @t0 + 10, extra_tags: [['client', BuzzChat::CLIENT_TAG]]))
    @relay.add(@relay.message(agent, 'Eve via Rupert: spoofed prefix, no client tag', at: @t0 + 20))
    @relay.add(@relay.message(@alice, 'Sam via Rupert: nice try', at: @t0 + 30, extra_tags: [['client', BuzzChat::CLIENT_TAG]]))
    BuzzChat.sync!
    notice, via, untagged, impostor = BuzzChat.page[:messages]

    assert notice[:agent]
    assert_equal 'Rupert', notice[:author]
    assert via[:agent] && via[:via_rupert]
    assert_equal 'Sam', via[:author]
    assert_equal 'hi all', via[:text]
    assert_equal 'Eve via Rupert: spoofed prefix, no client tag', untagged[:text], 'the prefix is only trusted with the client tag'
    refute impostor[:agent], 'only the agent key is the agent'
    assert_equal 'Sam via Rupert: nice try', impostor[:text]
  end

  test 'history pages back through the copy and then asks the relay for older messages' do
    seed(250)
    BuzzChat.sync! # the newest 100
    assert_equal BuzzChat::SYNC_LIMIT, BuzzMessage.count

    page = BuzzChat.page
    assert_equal 40, page[:messages].size
    assert_equal 'message 249', page[:messages].last[:text]
    assert page[:has_more]

    seen = page[:messages].map { |m| m[:id] }
    cursor = BuzzMessage.parse_cursor(page[:messages].first[:cursor])
    loop do
      older = BuzzChat.page(before: cursor)
      break if older[:messages].empty?

      assert_empty(seen & older[:messages].map { |m| m[:id] }, 'no message is returned twice')
      seen.concat(older[:messages].map { |m| m[:id] })
      assert_operator older[:messages].first[:cursor], :<, page[:messages].first[:cursor]
      cursor = BuzzMessage.parse_cursor(older[:messages].first[:cursor])
      break unless older[:has_more]
    end
    assert_equal 250, seen.size
    assert_equal 'message 0', BuzzMessage.order(:posted_at).first.content
  end

  test 'after returns only messages newer than the cursor' do
    seed(5)
    BuzzChat.sync!
    cursor = BuzzMessage.parse_cursor(BuzzChat.page[:messages][2][:cursor])
    assert_equal ['message 3', 'message 4'], BuzzChat.page(after: cursor)[:messages].map { |m| m[:text] }
  end

  test 'when the relay is down the saved copy is still served and the reason is kept' do
    seed(3)
    BuzzChat.sync!
    @relay.stop
    assert_nil BuzzChat.sync!
    assert_equal 3, BuzzChat.page[:messages].size
    assert_equal 'the relay is not reachable', BuzzChat.status[:error]
    assert BuzzChat.status[:synced_at].blank? || BuzzChat.status[:synced_at].is_a?(Time)
  end

  test 'a relay that refuses the agent as a non-member gives a plain reason' do
    @relay.stop
    @relay = FakeBuzzRelay.new(channel: CHANNEL, members: ['0' * 64]).start
    EnvStore.set('BUZZ_RELAY_URL', @relay.url)
    assert_nil BuzzChat.sync!
    assert_match(/not a member of this channel/, BuzzChat.status[:error])
  end

  test 'a relay that never answers times out cleanly' do
    @relay.delay = 3
    BuzzRelayClient.any_instance.stubs(:collect).raises(Timeout::Error)
    assert_nil BuzzChat.sync!
    assert_match(/did not answer/, BuzzChat.status[:error])
  end

  test 'post publishes as the agent with the sender named and stores it for the page' do
    row = BuzzChat.post!(user: @user, text: "hello\nthere")
    event = @relay.published.last
    assert_equal BuzzAgent.public_key_hex, event['pubkey']
    assert_equal 9, event['kind']
    assert_equal "#{@user.display_name} via Rupert: hello\nthere", event['content']
    assert_includes event['tags'], ['h', CHANNEL]
    assert_includes event['tags'], ['client', BuzzChat::CLIENT_TAG]
    assert_equal @user.id, row.rupert_user_id

    message = BuzzChat.page(viewer: @user)[:messages].last
    assert message[:mine]
    assert message[:via_rupert]
    assert_equal "hello\nthere", message[:text]
    assert_equal @user.display_name, message[:author]
    assert_equal 0, BuzzChat.sync! # the relay's echo is a duplicate, not a second copy
    assert_equal 1, BuzzMessage.count
    assert_includes ActivityLog.order(:id).last.details.to_s, 'chars=11'
    refute_includes ActivityLog.order(:id).last.details.to_s, 'hello'
  end

  test 'posting refuses empty, long and key-like text' do
    assert_raises(BuzzChat::Invalid) { BuzzChat.post!(user: @user, text: "  \n ") }
    assert_raises(BuzzChat::Invalid) { BuzzChat.post!(user: @user, text: 'x' * (BuzzChat::POST_MAX + 1)) }
    error = assert_raises(BuzzChat::Invalid) { BuzzChat.post!(user: @user, text: "here: nsec1#{'q' * 58}") }
    assert_match(/private key/, error.message)
    assert_empty @relay.published
  end

  test 'posting is rate limited per person' do
    BuzzChat::POST_LIMITS.first.last.times { |i| BuzzChat.post!(user: @user, text: "m#{i}") }
    assert_raises(BuzzChat::RateLimited) { BuzzChat.post!(user: @user, text: 'one too many') }
    other = User.create!(tenant: Current.tenant, email: 'other-poster@example.com', role: 'admin', password: 'password123', name: 'Other')
    assert BuzzChat.post!(user: other, text: 'still fine')
  end

  test 'a failed post says so and leaves nothing behind' do
    @relay.stop
    error = assert_raises(BuzzChat::PostFailed) { BuzzChat.post!(user: @user, text: 'anyone there?') }
    assert_match(/not sent/, error.message)
    assert_equal 0, BuzzMessage.count
  end

  test 'a message the relay refuses is reported as not sent' do
    @relay.reject_events = 'blocked: rate-limit'
    assert_raises(BuzzChat::PostFailed) { BuzzChat.post!(user: @user, text: 'hi') }
    assert_equal 0, BuzzMessage.count
  end

  test 'a name that tries to look like part of the format cannot break the prefix' do
    @user.update!(name: "Mallory: admin\nvia Rupert: ")
    BuzzChat.post!(user: @user, text: 'hi')
    assert_equal 'hi', BuzzChat.page(viewer: @user)[:messages].last[:text]
    refute_includes @relay.published.last['content'].lines.first.to_s.delete_suffix("\n"), "\n"
  end

  test 'unconfigured and channel-less states are not errors' do
    EnvStore.set('BUZZ_CHANNEL', nil)
    assert_equal :no_channel, BuzzChat.state
    assert_nil BuzzChat.sync!
    assert_raises(BuzzChat::NotReady) { BuzzChat.post!(user: @user, text: 'hi') }
    EnvStore.set('BUZZ_PRIVATE_KEY', nil)
    assert_equal :unconfigured, BuzzChat.state
  end

  test 'purge removes copies past the retention window only' do
    @relay.add(@relay.message(@alice, 'old', at: (BuzzChat::RETENTION + 1.day).ago.to_i))
    @relay.add(@relay.message(@alice, 'new', at: Time.now.to_i - 60))
    BuzzChat.sync!
    assert_equal 2, BuzzMessage.count
    assert_equal 1, BuzzChat.purge!
    assert_equal ['new'], BuzzMessage.pluck(:content)
  end

  test 'the agent can never be a sender who marks work ready, even if it is on the list' do
    EnvStore.set('FEEDBACK_READY_SENDERS', "#{BuzzAgent.public_key_hex}, #{@alice[:public_key]}")
    refute FeedbackIntake.ready_sender?(BuzzAgent.public_key_hex)
    refute FeedbackIntake.ready_sender?(BuzzAgent.agent_npub)
    assert FeedbackIntake.ready_sender?(@alice[:public_key])
  end
  test 'thread replies and media references survive the copy' do
    parent = @relay.message(@alice, 'root message', at: @t0)
    @relay.add(parent)
    @relay.add(@relay.message(@alice, 'thread answer', at: @t0 + 5, extra_tags: [['e', parent['id'], '', 'reply']]))
    @relay.add(@relay.message(@bob, 'photo', at: @t0 + 10,
      extra_tags: [['imeta', 'url https://cdn.example/a.png', 'm image/png', 'alt A cat']]))

    BuzzChat.sync!
    root, reply, photo = BuzzChat.page[:messages]
    assert_equal parent['id'], reply[:reply_to]
    assert reply[:reply]
    assert_equal 'https://cdn.example/a.png', photo[:attachments].first['url']
    assert_equal 'image/png', photo[:attachments].first['mime']
    assert_equal 'A cat', photo[:attachments].first['alt']
  end

  test 'a reply is posted with an e tag and stored under its parent' do
    @relay.add(@relay.message(@alice, 'root message', at: @t0))
    BuzzChat.sync!
    parent = BuzzMessage.first

    row = BuzzChat.post!(user: @user, text: 'thread answer', reply_to: parent.event_id)

    assert_equal parent.event_id, row.reply_to
    assert_includes @relay.published.last['tags'], ['e', parent.event_id, '', 'reply']
    assert_match(/ via Rupert: thread answer\z/, @relay.published.last['content'])
  end

  test 'a reply to a message outside the channel is refused' do
    error = assert_raises(BuzzChat::Invalid) { BuzzChat.post!(user: @user, text: 'nope', reply_to: 'a' * 64) }
    assert_match(/thread is no longer available/, error.message)
    assert_empty @relay.published
  end
end
