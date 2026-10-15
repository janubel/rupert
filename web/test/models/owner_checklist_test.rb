# frozen_string_literal: true

require 'test_helper'

class OwnerChecklistTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @actor = users(:regular_user)
    @checklist = OwnerChecklistWriter.create(attributes: { name: 'Owner', domain: 'store.example.com', purpose: 'Operations', owner_name: 'Owner' }, actor: @actor)
  end
  teardown { Current.reset }

  test 'public DNS syntax does not accept IP local URL or malformed hosts' do
    %w[example.com sub.example.com xn--bcher-kva.de].each { |value| assert OwnerChecklist.public_domain?(value), value }
    ['localhost', '127.0.0.1', '::1', '[::1]', 'store.local', 'store.internal', 'store.localhost', 'store.test', 'store.home.arpa',
      'store.onion', 'https://example.com', 'example.com/path', 'example.com.', '-bad.example.com', 'example..com', 'bücher.de'].each do |value|
      assert_not OwnerChecklist.public_domain?(value), value
    end
  end

  test 'login links are strict HTTPS public host references and perform no requests' do
    %w[https://example.com https://example.com:443/login https://vendor.example.com/account/login].each do |value|
      assert OwnerChecklist.valid_login_url?(value), value
    end
    ['http://example.com', 'https://example.com:444/login', 'https://user:pass@example.com', 'https://example.com?token=x',
      'https://example.com#secret', 'https://127.0.0.1', 'https://[::1]', 'https://store.internal', 'https://localhost',
      'https://store.local', 'https://store.home.arpa', 'https://user%40example.com', 'https://example.com/%0aToken',
      'https://example.com/%5cToken', "https://example.com\\@private.local", "https://example.com/\nToken", 'javascript:alert(1)',
      'https://example.com?', 'https://example.com#'].each do |value|
      assert_not OwnerChecklist.valid_login_url?(value), value.inspect
    end
    assert_not_requested :any, /.*/
  end

  test 'real business calendar dates reject rollover year zero and ambiguous formats' do
    assert_equal Date.new(2028, 2, 29), OwnerChecklist.calendar_date('2028-02-29')
    ['2026-02-29', '2026-02-30', '0000-01-01', '2026-1-1', '10/15/2026', '2026-10-15T12:00:00Z', nil].each do |value|
      assert_nil OwnerChecklist.calendar_date(value)
    end
  end

  test 'complete payload shapes and size are required and direct model saves require audited writer' do
    assert @checklist.persisted?
    value = @checklist.data
    value.delete('services')
    @checklist.payload_json = JSON.generate(value)
    assert_not @checklist.valid?
    @checklist.payload_json = JSON.generate(@checklist.data.merge('password' => 'secret'))
    assert_not @checklist.valid?
    @checklist.payload_json = 'x' * (OwnerChecklist::MAX_PAYLOAD_BYTES + 1)
    assert_not @checklist.valid?
    @checklist.payload_json = '[]'
    assert_not @checklist.valid?
    @checklist.payload_json = '{}'
    assert_not @checklist.valid?
    assert_not OwnerChecklist.new(tenant: Current.tenant, payload_json: '{}').valid?
  end

  test 'partial services and forged snapshot internals are rejected' do
    value = @checklist.data
    value['services'][SecureRandom.uuid] = { 'name' => 'Partial' }
    @checklist.writer_checked = true
    @checklist.payload_json = JSON.generate(value)
    assert_not @checklist.valid?
    feature = OwnerChecklist.features.first
    @checklist = OwnerChecklistWriter.review_feature(checklist: @checklist.reload, feature_id: feature['id'],
      attributes: { status: 'pending' }, lock_version: 0, actor: @actor)
    assert_empty @checklist.errors
    value = @checklist.data
    value['feature_reviews'][feature['id']]['catalog_scope'] = 'Forged scope'
    @checklist.writer_checked = true
    @checklist.payload_json = JSON.generate(value)
    assert_not @checklist.valid?
    value['feature_reviews'][feature['id']].delete('catalog_status')
    @checklist.payload_json = JSON.generate(value)
    assert_not @checklist.valid?
  end

  test 'history model rejects partial unsupported and cross store records' do
    event = @checklist.events.sole
    copy = OwnerChecklistEvent.new(tenant_id: Current.tenant_id, owner_checklist: @checklist, actor: @actor,
      action: 'create', payload_json: JSON.generate(event.data.except('actor_email')), writer_checked: true)
    assert_not copy.valid?
    copy.payload_json = JSON.generate(event.data.merge('password' => 'secret'))
    assert_not copy.valid?
    copy.payload_json = event.payload_json
    copy.tenant_id = 'other-store'
    assert_not copy.valid?
  end
end
