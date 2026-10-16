# frozen_string_literal: true

# Attention is derived from explicit controls and recorded activity, never from
# an assumed list of expected providers or a sum across currencies.
class ReconciliationAttention
  attr_reader :report

  def initialize(report)
    @report = report
  end

  def differences
    report.comparisons.reject { |row| row[:status] == 'Matched recorded total' }
      .sort_by { |row| self.class.sort_key(row) }
  end

  def self.sort_key(row)
    rank = { 'Variance' => 0, 'Conflicting controls' => 1, 'Unavailable in canonical records' => 2 }.fetch(row[:status], 3)
    [rank, row[:currency].to_s, -row[:delta_cents].to_i.abs, row[:source].to_s, row[:metric].to_s]
  end

  def missing_controls
    report.register.rows.reject do |row|
      report.controls.any? { |doc| doc.source == row[:source] && doc.metadata['currency'] == row[:currency] && doc.metadata['location_id'].presence == row[:location_id].presence }
    end
  end

  def control_key(row)
    Digest::SHA256.hexdigest([row[:source], row[:currency], row[:location_id].presence].to_json)
  end

  def counts
    { variances: report.comparisons.count { |row| row[:status] == 'Variance' },
      unavailable: report.comparisons.count { |row| row[:status] == 'Unavailable in canonical records' },
      conflicts: report.comparisons.count { |row| row[:status] == 'Conflicting controls' },
      missing_controls: missing_controls.size }
  end
end
