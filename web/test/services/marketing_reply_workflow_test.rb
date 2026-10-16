# frozen_string_literal: true

require 'test_helper'
require_relative '../support/marketing_setup'

class MarketingReplyWorkflowTest < ActiveSupport::TestCase
  include MarketingSetup
  setup { setup_marketing }
  teardown { Current.reset }

  test 'draft submit approve copy publish and remove preserve exact revisions without outbound requests' do
    reply = draft_reply
    transition(reply, 'submit')
    transition(reply, 'approve')
    text = transition(reply, 'copy')
    assert_includes text, @offer.code
    assert_includes text, @offer.terms
    assert_includes text, 'I work with Herbal Healers.'
    assert_includes text, 'utm_campaign=campaign-'
    refute_includes text, 'utm_source=old'
    transition(reply, 'publish', published_url: 'https://www.reddit.com/r/tea/comments/123/comment/456')
    assert_equal 'published', reply.reload.status
    assert_not_nil reply.published_at
    assert_equal %w[save submit approve copy publish], reply.review_events.order(:id).pluck(:action)
    transition(reply, 'remove', note: 'Moderator removed reply')
    assert_equal 'removed', reply.reload.status
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'save', attributes: { body: 'Try again' }) }
    assert_equal 'removed', reply.reload.status
    assert_requested(:any, /.*/, times: 0)
  end

  test 'copy and publication require approved status and a nonblank platform URL' do
    reply = draft_reply
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'copy') }
    transition(reply, 'submit')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'publish') }
    transition(reply, 'approve')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'publish') }
    assert_raises(ActiveRecord::RecordInvalid) { transition(reply, 'publish', published_url: 'https://different.org/reply') }
    assert_equal 'approved', reply.reload.status
  end

  test 'stale reply versions cannot overwrite or reapprove decisions' do
    reply = draft_reply
    old_version = reply.lock_version
    transition(reply, 'submit')
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::ReplyWorkflow.call(reply, action: 'approve', actor: @actor, version: old_version)
    end
    assert_equal 'pending_review', reply.reload.status
  end

  test 'editing text starts a new draft and keeps the prior review history' do
    reply = draft_reply
    transition(reply, 'submit')
    transition(reply, 'approve')
    snapshot = reply.snapshot_json
    transition(reply, 'save', attributes: { body: 'Updated useful advice' })
    assert_equal 'draft', reply.reload.status
    assert_nil reply.snapshot_digest
    assert_nil reply.snapshot_json
    assert_equal snapshot, JSON.parse(reply.review_events.find_by!(action: 'approve').payload_json)['snapshot']
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'copy') }
  end

  test 'offer edits clear verification and prevent copying an earlier approval' do
    reply = draft_reply
    transition(reply, 'submit')
    transition(reply, 'approve')
    @offer.update!(terms: '20% off with new restrictions')
    assert_nil @offer.reload.verified_at
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'copy') }
    @offer.update!(verified_at: Time.current, verified_by_id: @actor.id)
    assert @offer.reload.shareable?
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'copy') }
  end

  test 'campaign group and thread context changes invalidate an approved snapshot' do
    [@campaign, @community, @thread].each do |record|
      reply = draft_reply
      transition(reply, 'submit')
      transition(reply, 'approve')
      case record
      when Marketing::Campaign then record.update!(name: 'Revised campaign')
      when Marketing::Community then record.update!(promotion_rules: 'Offers only with moderator permission')
      when Marketing::Thread then record.update!(excerpt: 'Changed thread question')
      end
      assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'copy') }
      Marketing::ReviewEvent.where(reply_id: reply.id).delete_all
      reply.delete
      @community.reload.update!(rules_checked_at: Time.current)
      @thread.reload.update!(checked_at: Time.current)
    end
  end

  test 'stale rules context offers and locked threads block submission' do
    reply = draft_reply
    @offer.update!(verified_at: 25.hours.ago)
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'submit') }
    @offer.update!(verified_at: Time.current)
    @community.update!(rules_checked_at: 31.days.ago)
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'submit') }
    @community.update!(rules_checked_at: Time.current)
    @thread.update!(checked_at: 8.days.ago)
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'submit') }
    @thread.update!(availability: 'locked')
    @thread.update!(checked_at: Time.current)
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'submit') }
    @thread.update!(availability: 'open')
    @thread.update!(checked_at: Time.current, status: 'dismissed', triage_note: 'Not relevant')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'submit') }
  end

  test 'expiry after approval blocks copy even with unchanged context' do
    reply = draft_reply
    transition(reply, 'submit')
    transition(reply, 'approve')
    travel 3.days do
      assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'copy') }
      assert_raises(Marketing::ReplyWorkflow::Invalid) { transition(reply, 'publish', published_url: @thread.url) }
    end
  end

  test 'review permissions are distinct from writing and checked for inactive actors' do
    reply = draft_reply
    transition(reply, 'submit')
    @actor.user_permissions.create!(permission: 'marketing.read', enabled: true, tenant_id: @tenant.id)
    @actor.user_permissions.create!(permission: 'marketing.write', enabled: true, tenant_id: @tenant.id)
    @actor.reload
    assert_raises(Pundit::NotAuthorizedError) { transition(reply, 'approve') }
    @actor.user_permissions.create!(permission: 'marketing.review', enabled: true, tenant_id: @tenant.id)
    @actor.reload
    transition(reply, 'approve')
    @actor.update!(active: false)
    assert_raises(Pundit::NotAuthorizedError) { transition(reply, 'copy') }
  end

  test 'review events are immutable and event failure rolls back transition' do
    reply = draft_reply
    event = reply.review_events.first
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: 'approve') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
    Marketing::ReviewEvent.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)
    assert_raises(ActiveRecord::RecordInvalid) { transition(reply, 'submit') }
    assert_equal 'draft', reply.reload.status
  end

  test 'duplicate threads normalize tracking URLs and relevance explains include and exclude matches' do
    duplicate = @thread.dup
    duplicate.url = 'https://www.reddit.com/r/tea/comments/123/herbal?utm_campaign=duplicate'
    refute duplicate.valid?
    assert_includes duplicate.errors[:url], 'has already been taken'
    @thread.update!(excerpt: 'Herbal tea giveaway')
    assert_equal %w[herbal tea], @thread.relevance[:matched]
    assert_equal ['giveaway'], @thread.relevance[:excluded]
    assert_includes @community.search_url, 'bing.com/search?'
    assert_equal 'https://forum.org/view?id=123', Marketing::Urls.canonical('https://forum.org/view?id=123&utm_source=share')
    refute_equal Marketing::Urls.canonical('https://forum.org/view?id=123'), Marketing::Urls.canonical('https://forum.org/view?id=456')
  end

  test 'cross workspace associations and offer communities cannot be smuggled into drafts' do
    foreign = Tenant.create!(name: 'Other shop', subdomain: 'marketing-other')
    foreign_campaign = Marketing::Campaign.new(tenant_id: foreign.id, name: 'Private', topics: 'secret', storefront_url: 'https://other.org')
    foreign_campaign.save!
    bad = @community.dup
    bad.campaign = foreign_campaign
    refute bad.valid?
    second = @community.dup
    second.name = 'Another group'
    second.save!
    other_offer = @offer.dup
    other_offer.community = second
    other_offer.code = 'OTHER10'
    other_offer.save!
    reply = Marketing::Reply.new(thread: @thread)
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::ReplyWorkflow.call(reply, action: 'save', actor: @actor, attributes: { body: 'Advice', affiliation: 'Brand', offer_id: other_offer.id })
    end
    Current.tenant = foreign
    assert_raises(Marketing::ReplyWorkflow::Invalid, Pundit::NotAuthorizedError) { transition(draft_reply, 'submit') }
  end

  test 'unsafe URLs and nonstorefront offer destinations are rejected' do
    %w[http://www.reddit.com/a javascript:alert(1) https://localhost/a https://127.0.0.1/a https://[::1]/a https://user:pass@www.reddit.com/a https://host.internal/a].each do |url|
      refute Marketing::Urls.valid?(url), url
    end
    @offer.destination_url = 'https://attacker.org/shop'
    refute @offer.valid?
    @thread.url = 'https://attacker.org/thread'
    refute @thread.valid?
  end
end
