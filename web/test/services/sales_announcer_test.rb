# frozen_string_literal: true

require 'test_helper'

class SalesAnnouncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Setting.where(key: SalesAnnouncer::WATERMARK_KEY).delete_all
    LedgerEntry.where(tenant_id: Current.tenant_id).delete_all
    Current.tenant = nil
  end

  def make_entry(occurred_at, gross:, source: 'square', status: 'COMPLETED', summary: 'Honey Sticks')
    attrs = {
      source: source,
      sourceOrderId: SecureRandom.hex(8),
      orderName: 'SQ-test',
      occurredAt: occurred_at,
      syncedAt: Time.current,
      currency: 'USD',
      grossCents: gross,
      status: status,
      lineItems: 1,
      summary: summary,
      tenant_id: Current.tenant_id
    }
    LedgerEntry.create!({ id: "square:#{SecureRandom.hex(8)}" }.merge(attrs))
  end

  def announce!
    TeamChat::Notices.stubs(:configured?).returns(true)
    TeamChat::Notices.stubs(:notify).returns([true, 'OK'])
    SalesAnnouncer.announce!
  end

  test 'first run establishes a baseline and announces nothing' do
    old = make_entry(3.days.ago, gross: 1000)
    assert_equal 0, announce!
    watermark = JSON.parse(Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value)
    assert_equal old.occurredAt.utc.iso8601(6), watermark.fetch('occurred_at')
    assert_equal old.id, watermark.fetch('id')
  end

  test 'announces new sales after the baseline and advances the watermark' do
    make_entry(3.days.ago, gross: 1000)
    announce!
    new = make_entry(1.hour.ago, gross: 2500)

    capture = nil
    TeamChat::Notices.stubs(:notify).with do |content, *_|
      capture = content
      true
    end.returns([true, 'OK'])
    count = announce!

    assert_equal 1, count
    assert_includes capture, 'Honey Sticks'
    watermark = JSON.parse(Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value)
    assert_equal new.occurredAt.utc.iso8601(6), watermark.fetch('occurred_at')
    assert_equal new.id, watermark.fetch('id')
  end

  test 'posts total, then item and amount for each new sale' do
    make_entry(3.days.ago, gross: 1000)
    announce!
    make_entry(1.hour.ago, gross: 2500, summary: 'THCA Pre-Roll')
    make_entry(1.hour.ago, gross: 600, summary: 'Honey Sticks')

    capture = nil
    TeamChat::Notices.stubs(:notify).with do |content, *_|
      capture = content
      true
    end.returns([true, 'OK'])
    announce!

    assert_includes capture, '2 independent sale(s)'
    assert_includes capture, 'THCA Pre-Roll'
    assert_includes capture, '$25.00'
    assert_includes capture, 'Honey Sticks'
    assert_includes capture, '$6.00'
  end

  test 'ignores non-revenue statuses' do
    make_entry(3.days.ago, gross: 1000)
    announce!
    make_entry(1.hour.ago, gross: 2500, status: 'CANCELED')

    TeamChat::Notices.expects(:notify).never
    assert_equal 0, announce!
  end

  test 'no-ops when team chat is not in use' do
    TeamChat::Notices.stubs(:configured?).returns(false)
    assert_equal 0, SalesAnnouncer.announce!
  end

  test 'does not advance the watermark when publishing fails' do
    make_entry(3.days.ago, gross: 1000)
    announce!
    make_entry(1.hour.ago, gross: 2500)
    original = Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value

    TeamChat::Notices.stubs(:configured?).returns(true)
    TeamChat::Notices.stubs(:notify).returns([false, 'relay unavailable'])

    error = assert_raises(RuntimeError) { SalesAnnouncer.announce! }
    assert_includes error.message, 'relay unavailable'
    assert_equal original, Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value
  end

  test 'announces entries sharing a timestamp without skipping them' do
    old = make_entry(3.days.ago, gross: 1000)
    announce!
    occurred_at = 1.hour.ago.change(usec: 0)
    first = make_entry(occurred_at, gross: 2500)
    second = make_entry(occurred_at, gross: 600)

    TeamChat::Notices.stubs(:configured?).returns(true)
    TeamChat::Notices.stubs(:notify).returns([true, 'OK'])

    assert_equal 2, SalesAnnouncer.announce!
    watermark = JSON.parse(Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value)
    assert_equal [first.id, second.id].max, watermark.fetch('id')
    refute_equal old.id, watermark.fetch('id')
  end
end
