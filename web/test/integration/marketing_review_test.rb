# frozen_string_literal: true

require 'test_helper'
require_relative '../support/marketing_setup'

class MarketingReviewTest < ActionDispatch::IntegrationTest
  include MarketingSetup
  setup do
    setup_marketing
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end
  teardown { Current.reset }

  test 'workspace and forms render escaped context and bounded queue' do
    @thread.update!(excerpt: '<script>alert(1)</script> herbal tea')
    get marketing_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'Marketing'
    assert_includes response.body, '&lt;script&gt;alert(1)&lt;/script&gt;'
    assert_select "a[href='#{@community.search_url}']", text: 'Find threads with topic search'
    [new_marketing_campaign_path, edit_marketing_community_path(@community), edit_marketing_offer_path(@offer),
      edit_marketing_thread_path(@thread), new_marketing_reply_path(thread_id: @thread.id)].each do |path|
      get path
      assert_response :success, path
    end
    get marketing_path, params: { q: 'nonexistent' }
    refute_includes response.body, @thread.title
  end

  test 'operator saves triages reviews copies and records an exact reply with group code' do
    patch marketing_thread_path(@thread), params: { record: { lock_version: @thread.lock_version, status: 'relevant', triage_note: 'Relevant question' } }
    assert_redirected_to marketing_path
    post check_context_marketing_thread_path(@thread), params: { lock_version: @thread.reload.lock_version }
    assert_redirected_to marketing_path
    post marketing_replies_path, params: { reply: { thread_id: @thread.id, offer_id: @offer.id, body: 'Useful tea brewing advice', affiliation: 'I work with Herbal Healers.' } }
    reply = Marketing::Reply.last
    assert_redirected_to marketing_reply_path(reply)
    %w[submit approve copy].each do |action|
      post transition_marketing_reply_path(reply), params: { transition: action, lock_version: reply.reload.lock_version }
      assert_response(action == 'copy' ? :success : :redirect)
    end
    assert_select 'textarea[readonly]', text: /TEA10/
    post transition_marketing_reply_path(reply), params: { transition: 'publish', lock_version: reply.reload.lock_version, published_url: @thread.url }
    assert_redirected_to marketing_path
    assert_equal 'approved', reply.reload.status
    post transition_marketing_reply_path(reply), params: { transition: 'publish', lock_version: reply.lock_version, published_url: @thread.url, exact_text: '1' }
    assert_redirected_to marketing_reply_path(reply)
    assert_equal 'published', reply.reload.status
    get marketing_reply_path(reply)
    assert_response :success
    assert_select 'h2', 'Revision and review history'
  end

  test 'record forms accept new campaign group and code without allowing verification or tenant fields' do
    post marketing_campaigns_path, params: { record: { name: 'Second campaign', topics: 'tea', storefront_url: 'https://shop.herbalhealershcb.com', tenant_id: 'foreign' } }
    assert_redirected_to marketing_path
    assert_equal @tenant.id, Marketing::Campaign.last.tenant_id
    post marketing_communities_path, params: { record: { campaign_id: @campaign.id, name: 'New group', url: 'https://forum.herbalhealershcb.com/tea', include_terms: 'tea', promotion_rules: 'Offers allowed with disclosure', rules_url: 'https://forum.herbalhealershcb.com/rules', rules_checked_at: Time.current } }
    assert_redirected_to marketing_path
    group = Marketing::Community.last
    assert_nil group.rules_checked_at
    post check_rules_marketing_community_path(group), params: { lock_version: group.lock_version }
    assert_redirected_to marketing_path
    assert group.reload.rules_current?
    post marketing_offers_path, params: { record: { community_id: group.id, code: 'NEW10', terms: '10% off; one use; no stacking', destination_url: 'https://shop.herbalhealershcb.com/tea', starts_at: 1.hour.ago, ends_at: 2.days.from_now, evidence_url: @offer.evidence_url, verified_at: Time.current, verified_by_id: @actor.id } }
    assert_redirected_to marketing_path
    offer = Marketing::Offer.last
    assert_nil offer.verified_at
    post verify_marketing_offer_path(offer), params: { lock_version: offer.lock_version }
    assert_redirected_to marketing_path
    assert_nil offer.reload.verified_at
    post verify_marketing_offer_path(offer), params: { lock_version: offer.lock_version, confirmed: '1' }
    assert_redirected_to marketing_path
    assert offer.reload.shareable?
  end

  test 'duplicate intake links existing thread and does not reset its reply or triage' do
    reply = draft_reply
    post marketing_threads_path, params: { record: { community_id: @community.id, url: @thread.url + '?utm_source=copy', title: 'Duplicate', excerpt: 'Another excerpt' } }
    assert_redirected_to edit_marketing_thread_path(@thread)
    assert_equal 1, Marketing::Thread.count
    assert_equal 'relevant', @thread.reload.status
    assert_equal reply.id, @thread.reply.id
  end

  test 'disabled module gates direct routes and admin can enable it' do
    Current.tenant = @tenant
    FeatureFlag.set(:marketing, false)
    get new_marketing_thread_path
    assert_response :not_found
    get marketing_path
    assert_select 'button', 'Enable Marketing'
    post marketing_toggle_path, params: { enabled: '1' }
    assert_redirected_to marketing_path
    get new_marketing_thread_path
    assert_response :success
  end

  test 'read only user cannot write review or enable and cannot access another tenant records' do
    reply = draft_reply
    @actor.update!(role: 'reader')
    @actor.user_permissions.create!(permission: 'marketing.read', enabled: true, tenant_id: @tenant.id)
    get marketing_path
    assert_response :success
    get marketing_reply_path(reply)
    assert_response :success
    get new_marketing_thread_path
    assert_response :redirect
    post transition_marketing_reply_path(reply), params: { transition: 'submit', lock_version: reply.lock_version }
    assert_response :redirect
    post marketing_toggle_path, params: { enabled: '0' }
    assert_response :redirect
    Current.tenant = @tenant
    assert FeatureFlag.enabled?(:marketing)
    foreign = Tenant.create!(name: 'Foreign', subdomain: 'private-marketing')
    foreign_campaign = Marketing::Campaign.create!(tenant_id: foreign.id, name: 'SECRET CAMPAIGN', topics: 'private', storefront_url: 'https://private.org')
    get marketing_path
    refute_includes response.body, 'SECRET CAMPAIGN'
    @actor.update!(role: 'admin')
    @actor.user_permissions.delete_all
    get edit_marketing_campaign_path(foreign_campaign)
    assert_response :not_found
  end

  test 'stale record edits fail without overwriting newer context and signed out requests are gated' do
    version = @campaign.lock_version
    @campaign.update!(topics: 'new topics')
    patch marketing_campaign_path(@campaign), params: { record: { lock_version: version, topics: 'stale topics' } }
    assert_redirected_to marketing_path
    assert_equal 'new topics', @campaign.reload.topics
    delete logout_path
    get marketing_path
    assert_redirected_to login_path
  end
end
