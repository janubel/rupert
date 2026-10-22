# frozen_string_literal: true

require 'test_helper'

class SalesAnnouncementJobTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
  end

  teardown do
    Setting.where(key: SalesAnnouncer::WATERMARK_KEY).delete_all
    LedgerEntry.where(tenant_id: @tenant.id).delete_all
    Current.tenant = nil
  end

  def make_entry(occurred_at, gross:, tenant: @tenant, status: 'COMPLETED', summary: 'Honey Sticks')
    attrs = {
      source: 'square',
      sourceOrderId: SecureRandom.hex(8),
      orderName: 'SQ-test',
      occurredAt: occurred_at,
      syncedAt: Time.current,
      currency: 'USD',
      grossCents: gross,
      status: status,
      lineItems: 1,
      summary: summary,
      tenant_id: tenant.id
    }
    LedgerEntry.create!({ id: "square:#{SecureRandom.hex(8)}" }.merge(attrs))
  end

  test 'job announces new sales within the tenant scope' do
    TeamChat::Notices.stubs(:configured?).returns(true)
    make_entry(3.days.ago, gross: 1000)
    SalesAnnouncementJob.perform_now(@tenant.id)

    make_entry(1.hour.ago, gross: 2500, summary: 'THCA Pre-Roll')

    capture = nil
    TeamChat::Notices.stubs(:notify).with do |content, *_|
      capture = content
      true
    end.returns([true, 'OK'])

    SalesAnnouncementJob.perform_now(@tenant.id)

    assert_includes capture, 'THCA Pre-Roll'
    assert_includes capture, '$25.00'
  end

  test 'job does not leak tenant across tenants' do
    TeamChat::Notices.stubs(:configured?).returns(true)
    other = Tenant.create!(name: 'Other Co', subdomain: 'otherco')
    make_entry(3.days.ago, gross: 1000, tenant: @tenant)
    SalesAnnouncementJob.perform_now(@tenant.id)

    make_entry(1.hour.ago, gross: 9999, summary: 'Other Sale', tenant: other)

    capture = nil
    TeamChat::Notices.stubs(:notify).with do |content, *_|
      capture = content
      true
    end.returns([true, 'OK'])

    SalesAnnouncementJob.perform_now(@tenant.id)

    assert_nil capture
    other.destroy
  end

  test 'job discards and clears tenant when the tenant is gone' do
    missing = Tenant.create!(name: 'Gone', subdomain: 'goneco')
    missing.destroy

    TeamChat::Notices.stubs(:configured?).returns(true)
    assert_nothing_raised { SalesAnnouncementJob.perform_now(missing.id) }
    assert_nil Current.tenant
  end
end
