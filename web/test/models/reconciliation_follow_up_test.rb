# frozen_string_literal: true

require 'test_helper'

class ReconciliationFollowUpTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'square', document_kind: 'register_control',
      period_from: '2026-10-14', period_to: '2026-10-14', currency: 'USD', title: 'Register original needed', notes: 'Ask for the original report.',
      due_on: '2026-10-15', submission_key: SecureRandom.uuid)
  end
  teardown { Current.reset }

  test 'control evidence must match currency location and whole requested coverage' do
    wrong = ReconciliationEvidence.retain!(bytes: 'foreign scope', filename: 'control.txt', source: 'square', kind: 'register_control',
      from: '2026-10-14', to: '2026-10-14', metadata: { currency: 'EUR', cash: 100 })
    refute @item.update(document_id: wrong.id, notes: 'Wrong currency')
    right = ReconciliationEvidence.retain!(bytes: 'matching scope', filename: 'control.txt', source: 'square', kind: 'register_control',
      from: '2026-10-14', to: '2026-10-14', metadata: { currency: 'USD', cash: 100 })
    assert_equal [right.id], @item.matching_documents.map(&:id)
    assert @item.update(document_id: right.id, notes: 'Matched scope, still checking the figures.')
    assert_equal 'open', @item.reload.status
    assert_equal 2, @item.events.count
  end

  test 'source context remains fixed and a failed history write rolls back the current update' do
    refute @item.update(source: 'bank')
    @item.reload
    @item.events.stubs(:create!).raises(ActiveRecord::RecordNotSaved, 'History unavailable')
    assert_raises(ActiveRecord::RecordNotSaved) { @item.update!(status: 'closed', notes: 'Closing explanation') }
    assert_equal 'open', @item.reload.status
    assert_equal 'Ask for the original report.', @item.notes
    assert_equal 1, @item.events.count
  end
  test 'platform administrators retain actor attribution when working in another authorized workspace' do
    other = Tenant.create!(name: 'Platform home', subdomain: 'platform-home')
    actor = User.create!(tenant: other, email: 'platform-reviewer@example.com', name: 'Platform reviewer', role: 'super_admin', password: 'password123')
    workspace = Current.tenant
    Current.user = actor
    Current.tenant = workspace
    values = @item.attributes.slice('category', 'source', 'document_kind', 'period_from', 'period_to', 'currency', 'title', 'notes', 'due_on')
    cross_workspace = ReconciliationFollowUp.create!(values.merge(created_by: actor, submission_key: SecureRandom.uuid))
    assert_equal actor.id, cross_workspace.events.first.details['actor_id']
    assert_equal 'Platform reviewer', cross_workspace.events.first.details['actor_name']
    refute cross_workspace.update(owner: actor, notes: 'Cross-workspace ownership is not offered.')
  end
end
