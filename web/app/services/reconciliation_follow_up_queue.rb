# frozen_string_literal: true

# A structured, local navigation destination. Never accept a return URL.
class ReconciliationFollowUpQueue
  KEYS = %i[status source owner category evidence original day].freeze
  STATUSES = { 'active' => 'Open or waiting', 'open' => 'Open', 'waiting' => 'Waiting', 'closed' => 'Closed',
    'overdue' => 'Overdue', 'today' => 'Due today', 'all' => 'All statuses' }.freeze
  attr_reader :status, :source, :owner, :category, :evidence, :original, :day

  def initialize(values = {})
    values = values.with_indifferent_access
    @status = STATUSES.include?(values[:status]) ? values[:status] : 'active'
    @source = ReconciliationDocument::SOURCES.excluding('rupert').include?(values[:source]) ? values[:source] : nil
    @owner = %w[mine unassigned].include?(values[:owner]) ? values[:owner] : nil
    @category = ReconciliationFollowUp::CATEGORIES.key?(values[:category]) ? values[:category] : nil
    @evidence = values[:evidence] == 'missing' ? 'missing' : nil
    @original = ReconciliationDocument.find(values[:original]) if values[:original].present?
    @day = ReconciliationEvidence.dates(values[:day], values[:day]).first if values[:day].present?
  end

  def filters
    { status: status, source: source, owner: owner, category: category, evidence: evidence,
      original: original&.id, day: day&.iso8601 }.compact
  end
end
