# frozen_string_literal: true

# Match coverage metadata only; never read original bytes or infer native CSV coverage.
class ReconciliationDocumentFollowUps
  Match = Struct.new(:items, :total, keyword_init: true)

  def self.scope_for(doc)
    scope = ReconciliationFollowUp.where(tenant_id: doc.tenant_id, source: doc.source, document_kind: doc.kind)
      .where('period_from >= ? AND period_to <= ?', doc.period_from, doc.period_to)
    return scope.none unless ReconciliationFollowUp::DOCUMENT_KINDS.include?(doc.kind)

    if doc.kind == 'register_control'
      scope = scope.where(currency: doc.metadata['currency'])
      location = doc.metadata['location_id'].presence
      scope = scope.where(location_id: location || [nil, ''])
    end
    scope
  end

  def self.for(doc)
    scope = scope_for(doc).active
    Match.new(total: scope.count, items: scope.select(:id, :title, :due_on, :status, :document_id).order(:due_on, :id).limit(3).to_a)
  end
end
