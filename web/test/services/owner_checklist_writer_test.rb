# frozen_string_literal: true

require 'test_helper'

class OwnerChecklistWriterTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @actor = users(:regular_user)
    @metadata = { name: 'Owner operations', domain: 'OwnerExample.org', purpose: 'Private store services',
      owner_name: 'Private Owner', owner_email: 'owner@example.com', owner_phone: '555-123-4567', notes: 'Private owner notes' }
  end
  teardown { Current.reset }

  test 'creates encrypted metadata with an encrypted immutable operator snapshot' do
    checklist = create_checklist
    assert_equal 'ownerexample.org', checklist.data.fetch('domain')
    assert_equal '555-123-4567', checklist.data.fetch('owner_phone')
    assert_equal @actor.id, checklist.created_by_id
    assert_equal @actor.id, checklist.updated_by_id
    assert_equal 0, checklist.lock_version
    event = checklist.owner_checklist_events.sole
    assert_equal 'create', event.action
    assert_equal checklist.data, event.data.fetch('after')
    assert_equal @actor.email, event.data.fetch('actor_email')
    assert_equal @actor.display_name, event.data.fetch('actor_name')
    assert_equal 1, checklist.events.count
    assert_encrypted(checklist, %w[ownerexample.org owner@example.com Private])
    assert_encrypted(event, %w[ownerexample.org owner@example.com Private admin@example.com])
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: 'update') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    assert_raises(ActiveRecord::DeleteRestrictionError) { checklist.destroy! }
  end

  test 'unsupported credential fields and malformed metadata never write' do
    %i[password token api_key card_number payload_json services feature_reviews].each do |field|
      assert_no_difference %w[OwnerChecklist.count OwnerChecklistEvent.count] do
        model = OwnerChecklistWriter.create(attributes: @metadata.merge(field => 'PRIVATE-SECRET'), actor: @actor)
        assert model.errors.any?
        assert_not_includes model.errors.full_messages.join, 'PRIVATE-SECRET'
        assert_not_includes model.data.inspect, 'PRIVATE-SECRET'
      end
    end
    assert_no_difference 'OwnerChecklist.count' do
      model = OwnerChecklistWriter.create(attributes: @metadata.merge(name: ['invalid'], owner_phone: 'p' * 81), actor: @actor)
      assert model.errors.any?
    end
  end

  test 'metadata update advances version and history with only the affected section' do
    checklist = create_checklist
    updated = OwnerChecklistWriter.update(checklist: checklist, attributes: { notes: 'Reviewed private note' },
      lock_version: '0', actor: @actor)
    assert_empty updated.errors
    assert_equal 1, updated.lock_version
    assert_equal 'Reviewed private note', updated.data['notes']
    assert_encrypted(updated, ['Reviewed private note', 'owner@example.com'])
    event = updated.events.order(:id).last
    assert_equal 'update', event.action
    assert_equal 'Private owner notes', event.data.dig('before', 'notes')
    assert_equal 'Reviewed private note', event.data.dig('after', 'notes')
    assert_not event.data['after'].key?('services')
    assert_encrypted(event, ['Reviewed private note'])
  end

  test 'old version cannot overwrite a newer saved record or append history' do
    checklist = create_checklist
    update_checklist(checklist, { notes: 'First edit' })
    assert_no_difference 'OwnerChecklistEvent.count' do
      assert_raises(ActiveRecord::StaleObjectError) do
        OwnerChecklistWriter.update(checklist: checklist, attributes: { notes: 'Stale edit' }, lock_version: 0, actor: @actor)
      end
    end
    assert_equal 'First edit', checklist.reload.data['notes']
    [nil, '', -1, '01', '0junk', 1.0, '2147483647'].each do |version|
      assert_raises(ActiveRecord::StaleObjectError) do
        OwnerChecklistWriter.update(checklist: checklist, attributes: {}, lock_version: version, actor: @actor)
      end
    end
  end

  test 'a stale ruby object with the current submitted version preserves other sections' do
    checklist = create_checklist
    saved = save_service(checklist)
    updated = OwnerChecklistWriter.update(checklist: checklist, attributes: { notes: 'Latest edit' },
      lock_version: saved.lock_version, actor: @actor)
    assert_empty updated.errors
    assert_equal 1, updated.services.length
    assert_equal 'Vendor account', updated.services.values.sole['name']
    assert_equal 2, updated.lock_version
  end

  test 'creation and each edit roll back when mandatory encrypted history fails' do
    OwnerChecklistEvent.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(OwnerChecklistEvent.new))
    assert_no_difference %w[OwnerChecklist.count OwnerChecklistEvent.count] do
      assert_raises(ActiveRecord::RecordInvalid) { OwnerChecklistWriter.create(attributes: @metadata, actor: @actor) }
    end
    OwnerChecklistEvent.unstub(:create!)
    checklist = create_checklist
    OwnerChecklistEvent.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(OwnerChecklistEvent.new))
    assert_no_difference 'OwnerChecklistEvent.count' do
      assert_raises(ActiveRecord::RecordInvalid) { update_checklist(checklist, { notes: 'Must roll back' }) }
    end
    assert_equal 'Private owner notes', checklist.reload.data['notes']
    assert_equal 0, checklist.lock_version
  end

  test 'service uses a server generated UUID and encrypted contact and schedule data' do
    checklist = save_service(create_checklist, { support_email: 'support@example.com', support_phone: '555-888-9999',
      login_url: 'https://vendor.example.com/login', renewal_on: '2028-02-29', next_review_on: '2026-12-01',
      vault_reference: 'Operations vault / vendor item', notes: 'Private service instructions' })
    assert_empty checklist.errors
    id, service = checklist.services.first
    assert_match OwnerChecklist::UUID, id
    assert_equal false, service['archived']
    assert_equal 'unspecified', service['renewal_cadence']
    assert_equal 'unknown', service['mfa_status']
    assert_equal 1, checklist.lock_version
    event = checklist.events.order(:id).last
    assert_equal id, event.data['service_id']
    assert_equal service, event.data['after']
    assert_encrypted(checklist, ['support@example.com', '555-888-9999', 'vendor.example.com', 'Private service instructions'])
    assert_encrypted(event, ['support@example.com', 'vendor.example.com', 'Operations vault'])
  end

  test 'only existing service identities can be edited and archive accepts exact checkbox booleans' do
    checklist = save_service(create_checklist)
    id = checklist.services.keys.sole
    checklist = OwnerChecklistWriter.save_service(checklist: checklist, service_id: id, attributes: { archived: '1' },
      lock_version: checklist.lock_version, actor: @actor)
    assert_equal true, checklist.services[id]['archived']
    checklist = OwnerChecklistWriter.save_service(checklist: checklist, service_id: id, attributes: { archived: '0' },
      lock_version: checklist.lock_version, actor: @actor)
    assert_equal false, checklist.services[id]['archived']
    [SecureRandom.uuid, 'invalid'].each do |service_id|
      assert_no_difference 'OwnerChecklistEvent.count' do
        invalid = OwnerChecklistWriter.save_service(checklist: checklist, service_id: service_id, attributes: {},
          lock_version: checklist.lock_version, actor: @actor)
        assert invalid.errors.any?
      end
    end
    invalid = OwnerChecklistWriter.save_service(checklist: checklist, service_id: id, attributes: { archived: 'false' },
      lock_version: checklist.lock_version, actor: @actor)
    assert invalid.errors.any?
    assert_equal 'false', invalid.services[id]['archived']
  end

  test 'service limits include archived records and reject invalid schedule and credential data' do
    checklist = create_checklist
    20.times { checklist = save_service(checklist) }
    assert_equal 20, checklist.services.length
    invalid = save_service(checklist)
    assert invalid.errors.any?
    assert_equal 20, checklist.reload.services.length
    [{ renewal_on: '2026-02-30' }, { next_review_on: '0000-01-01' }, { renewal_cadence: 'weekly' },
      { mfa_status: 'disabled' }, { password: 'PRIVATE' }, { vault_reference: 'https://vault.example.com/item' },
      { support_email: 'broken' }, { notes: 'n' * 2001 }].each do |attributes|
      assert_no_difference 'OwnerChecklistEvent.count' do
        invalid = OwnerChecklistWriter.save_service(checklist: checklist, service_id: checklist.services.keys.first,
          attributes: attributes, lock_version: checklist.lock_version, actor: @actor)
        assert invalid.errors.any?, attributes.keys.inspect
      end
    end
  end

  test 'passed review needs genuine date evidence and exact affirmative scope attestation' do
    checklist = create_checklist
    feature = OwnerChecklist.features.find { |entry| entry['status'] != 'Planned' }
    [{ evidence: '' }, { tested_on: '' }, { tested_on: '2026-02-30' }, { tested_on: (Date.current + 1).iso8601 },
      { attest_scope: false }, { attest_scope: '0' }, { attest_scope: 'false' }, { attest_scope: 'true' }].each do |change|
      assert_no_difference 'OwnerChecklistEvent.count' do
        result = review(checklist, feature, { status: 'passed', evidence: 'Local acceptance checked',
          tested_on: Date.current.iso8601, attest_scope: '1' }.merge(change))
        assert result.errors.any?, change.inspect
      end
    end
    checklist = review(checklist, feature, status: 'passed', evidence: 'Private acceptance evidence',
      tested_on: Date.current.iso8601, attest_scope: '1')
    assert_empty checklist.errors
    assert_equal 'passed', checklist.feature_review(feature)['status']
    assert_equal true, checklist.feature_review(feature)['attest_scope']
    assert_equal @actor.email, checklist.feature_review(feature)['reviewer']
    assert_encrypted(checklist, ['Private acceptance evidence'])
    assert_encrypted(checklist.events.order(:id).last, ['Private acceptance evidence'])
  end

  test 'planned unknown and forged catalog reviews cannot pass' do
    checklist = create_checklist
    planned = OwnerChecklist.features.find { |entry| entry['status'] == 'Planned' }
    result = review(checklist, planned, status: 'passed', evidence: 'Attempted', tested_on: Date.current.iso8601, attest_scope: true)
    assert result.errors.any?
    result = review(checklist, { 'id' => 'F99999' }, status: 'pending')
    assert result.errors.any?
    feature = OwnerChecklist.features.first
    %w[reviewer catalog_status catalog_scope catalog_fingerprint password].each do |key|
      result = review(checklist, feature, { status: 'pending', key => 'FORGED' })
      assert result.errors.any?
      assert_not_includes result.data.inspect, 'FORGED'
    end
    assert_empty checklist.reload.feature_reviews
  end

  test 'not required needs a reason and catalog drift invalidates passed and not required' do
    checklist = create_checklist
    feature = OwnerChecklist.features.find { |entry| entry['status'] != 'Planned' }
    assert review(checklist, feature, status: 'not_required').errors.any?
    %w[not_required passed].each do |status|
      checklist = review(checklist, feature, status: status, evidence: 'Reviewed scope', tested_on: Date.current.iso8601, attest_scope: true)
      assert_empty checklist.errors
      %w[name scope status].each do |field|
        changed = feature.merge(field => "Changed #{field}")
        assert_equal 'stale', checklist.feature_review(changed)['status']
      end
      assert_equal status, checklist.feature_reviews[feature['id']]['status']
      updated = update_checklist(checklist, { notes: 'Unrelated edit preserves review snapshot' })
      assert_empty updated.errors
      checklist = updated
    end
    assert_equal 'not_reviewed', checklist.feature_review({ 'id' => 'F99999', 'name' => 'Future', 'scope' => 'New', 'status' => 'Planned' })['status']
  end

  test 'final reviews require the displayed scope fingerprint and cannot inherit a changed scope' do
    checklist = create_checklist
    feature = OwnerChecklist.features.find { |entry| entry['status'] != 'Planned' }
    attributes = { status: 'passed', evidence: 'Tested prior scope', tested_on: Date.current.iso8601, attest_scope: true }
    [nil, '0' * 64].each do |fingerprint|
      assert_no_difference 'OwnerChecklistEvent.count' do
        invalid = OwnerChecklistWriter.review_feature(checklist: checklist, feature_id: feature['id'], attributes: attributes,
          lock_version: 0, actor: @actor, expected_catalog_fingerprint: fingerprint)
        assert invalid.errors.any?
        assert_empty checklist.reload.feature_reviews
      end
    end
    old_fingerprint = OwnerChecklist.catalog_fingerprint(feature)
    OwnerChecklist.stubs(:features).returns([feature.merge('scope' => 'Newly expanded scope')])
    invalid = OwnerChecklistWriter.review_feature(checklist: checklist, feature_id: feature['id'], attributes: attributes,
      lock_version: 0, actor: @actor, expected_catalog_fingerprint: old_fingerprint)
    assert invalid.errors.any?
    assert_empty checklist.reload.feature_reviews
  end

  test 'fresh database authority defeats forged roles and deactivated actors or tenants' do
    checklist = create_checklist
    @actor.update_columns(role: 'manager')
    @actor.role = 'admin'
    assert_raises(ActiveRecord::RecordNotFound) { update_checklist(checklist, { notes: 'No' }) }
    @actor.update_columns(role: 'admin', active: false)
    @actor.active = true
    assert_raises(ActiveRecord::RecordNotFound) { OwnerChecklistWriter.create(attributes: @metadata, actor: @actor) }
    @actor.update_columns(active: true)
    Current.tenant.update_columns(status: 'inactive')
    Current.tenant.status = 'active'
    assert_raises(ActiveRecord::RecordNotFound) { update_checklist(checklist, {}) }
  end

  test 'admin cannot cross tenants but selected active super admin workspace is supported' do
    checklist = create_checklist
    other = Tenant.create!(name: 'Other', subdomain: 'other-checklist', status: 'active')
    Current.tenant = other
    assert_raises(ActiveRecord::RecordNotFound) { OwnerChecklistWriter.create(attributes: @metadata, actor: @actor) }
    @actor.update_columns(role: 'super_admin')
    second = OwnerChecklistWriter.create(attributes: @metadata, actor: @actor)
    assert second.persisted?
    assert_equal other.id, second.tenant_id
    assert_raises(ActiveRecord::RecordNotFound) { update_checklist(checklist, {}) }
    assert_nil OwnerChecklist.find_by(id: checklist.id)
    assert_nil OwnerChecklistEvent.find_by(owner_checklist_id: checklist.id)
  end

  test 'deleting an operator nullifies foreign keys and retains encrypted actor provenance' do
    actor = User.create!(tenant: Current.tenant, role: 'admin', active: true, name: 'Former Owner',
      email: 'former@example.com', password: 'password123')
    checklist = OwnerChecklistWriter.create(attributes: @metadata, actor: actor)
    event = checklist.events.sole
    actor.destroy!
    assert_nil checklist.reload.created_by_id
    assert_nil checklist.updated_by_id
    assert_nil event.reload.actor_id
    assert_equal 'Former Owner', event.data['actor_name']
    assert_equal 'former@example.com', event.data['actor_email']
  end

  private

  def create_checklist
    result = OwnerChecklistWriter.create(attributes: @metadata, actor: @actor)
    assert result.persisted?, result.errors.full_messages.join('; ')
    result
  end

  def update_checklist(checklist, attributes)
    OwnerChecklistWriter.update(checklist: checklist, attributes: attributes, lock_version: checklist.lock_version, actor: @actor)
  end

  def save_service(checklist, attributes = {})
    OwnerChecklistWriter.save_service(checklist: checklist, attributes: { name: 'Vendor account', purpose: 'Store operations' }.merge(attributes),
      lock_version: checklist.lock_version, actor: @actor)
  end

  def review(checklist, feature, attributes)
    OwnerChecklistWriter.review_feature(checklist: checklist, feature_id: feature['id'], attributes: attributes,
      lock_version: checklist.lock_version, actor: @actor, expected_catalog_fingerprint: OwnerChecklist.catalog_fingerprint(feature))
  end

  def assert_encrypted(record, secrets)
    connection = record.class.connection
    raw = connection.select_value("SELECT payload_json FROM #{connection.quote_table_name(record.class.table_name)} WHERE id = #{connection.quote(record.id)}")
    secrets.each { |secret| assert_not_includes raw, secret }
    assert_not_equal record.payload_json, raw
  end
end

class OwnerChecklistWriterConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = Tenant.create!(name: 'Checklist race', subdomain: "checklist-race-#{SecureRandom.hex(4)}", status: 'active')
    Current.tenant = @tenant
    @actor = User.create!(tenant: @tenant, role: 'admin', active: true,
      email: "checklist-race-#{SecureRandom.hex(4)}@example.com", password: 'password123')
    @checklist = OwnerChecklistWriter.create(attributes: { name: 'Race', domain: 'store.example.com',
      purpose: 'Concurrent edits', owner_name: 'Owner' }, actor: @actor)
    assert @checklist.persisted?
  end

  teardown do
    Current.tenant = @tenant
    OwnerChecklistEvent.delete_all
    OwnerChecklist.delete_all
    @actor&.destroy!
    @tenant&.destroy!
    Current.reset
  end

  test 'two database sessions using one version save exactly one change and encrypted event' do
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = Array.new(2) do |number|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = @tenant
          selected = OwnerChecklist.find(@checklist.id)
          ready << true
          start.pop
          outcomes << OwnerChecklistWriter.update(checklist: selected, attributes: { notes: "Private concurrent edit #{number}" },
            lock_version: 0, actor: @actor)
        ensure
          Current.reset
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent checklist edit timed out' }
    results = Array.new(2) { outcomes.pop }
    assert_equal 1, results.count { |result| result.is_a?(OwnerChecklist) }, results.map(&:class).inspect
    assert_equal 1, results.count { |result| result.is_a?(ActiveRecord::StaleObjectError) }, results.map(&:class).inspect
    assert_equal 1, @checklist.reload.lock_version
    assert_match(/Private concurrent edit [01]/, @checklist.data['notes'])
    assert_equal 2, @checklist.events.count
    assert_equal 1, @checklist.events.where(action: 'update').count
    assert_equal @checklist.data['notes'], @checklist.events.where(action: 'update').sole.data.dig('after', 'notes')
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
