# frozen_string_literal: true

require 'test_helper'

class ReconciliationDocumentFollowUpsTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'full requested period and source kind are required without decrypting original bytes' do
    doc = ReconciliationEvidence.retain!(bytes: 'synthetic statement', filename: 'statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
    values = { category: 'missing_report', source: 'bank', document_kind: 'bank_statement', title: 'Statement needed', notes: 'Find the original.',
      period_from: '2026-10-01', period_to: '2026-10-31', due_on: '2026-11-02', submission_key: SecureRandom.uuid }
    match = ReconciliationFollowUp.create!(values)
    [{ period_from: '2026-09-30' }, { period_to: '2026-11-01' }, { source: 'square' }, { document_kind: 'invoice' }].each do |changes|
      ReconciliationFollowUp.create!(values.merge(changes).merge(submission_key: SecureRandom.uuid))
    end
    doc.stubs(:original_bytes).raises('Original bytes must not be loaded')
    result = ReconciliationDocumentFollowUps.for(doc)
    assert_equal 1, result.total
    assert_equal [match.id], result.items.map(&:id)
    refute result.items.first.has_attribute?(:notes)
    other = Tenant.create!(name: 'Foreign document requests', subdomain: 'foreign-document-requests')
    Current.set(tenant: other) { assert_empty ReconciliationDocumentFollowUps.scope_for(doc) }
  end
end
