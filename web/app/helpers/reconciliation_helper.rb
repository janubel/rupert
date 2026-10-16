# frozen_string_literal: true

module ReconciliationHelper
  def reconciliation_source(source)
    ReconciliationLibrary::SOURCE_NAMES.fetch(source, source.to_s.humanize)
  end

  def reconciliation_money(cents)
    cents.nil? ? 'Unavailable' : number_with_precision(BigDecimal(cents.to_s) / 100, precision: 2, delimiter: ',')
  end

  def reconciliation_tone(status)
    case status
    when 'reviewed', 'Matched recorded total' then 'border-emerald-200 bg-emerald-50 text-emerald-900'
    when 'Variance', 'needs_attention', 'Conflicting controls' then 'border-amber-300 bg-amber-50 text-amber-950'
    else 'border-fog bg-haze text-mocha'
    end
  end

  def reconciliation_document_state(doc, successor = nil)
    return 'Withdrawal record' if doc.metadata['withdrawn']
    return successor.metadata['withdrawn'] ? 'Withdrawn control' : 'Previous version' if successor
    return 'Current control' if doc.kind == 'register_control'
    return 'Report archive' if %w[daily_archive period_archive].include?(doc.kind)
    return 'Normalized snapshot' if doc.metadata['coverage'] == 'normalized_source_snapshot'

    doc.supersedes_id ? 'Correction retained' : 'Original retained'
  end

  def reconciliation_form_value(key, default = nil)
    @evidence_values&.key?(key.to_s) ? @evidence_values[key.to_s] : default
  end
end
