# frozen_string_literal: true

# A bounded, live view of local controls and saved requests. It does not fetch
# providers, decrypt file bodies, infer report expectations or certify review.
class ReconciliationAcrossDays
  attr_reader :ending_on

  def initialize(ending_on: Date.yesterday.iso8601)
    @ending_on = ReconciliationEvidence.dates(ending_on, ending_on).first
  end

  def starting_on
    ending_on - 6
  end

  def days
    @days ||= (starting_on..ending_on).to_a.reverse.map do |day|
      report = DailyMoneyReconciliation.new(day: day.iso8601)
      attention = ReconciliationAttention.new(report)
      missing = attention.missing_controls.map do |row|
        row.merge(request_id: requests[[day, row[:source], row[:currency], row[:location_id].presence]])
      end
      { day: day, counts: attention.counts, missing: missing,
        untracked: missing.count { |row| row[:request_id].nil? },
        follow_ups: periods.sum { |(from, to), count| day.between?(from, to) ? count : 0 } }
    end
  end

  def days_needing_attention
    days.count { |row| row[:counts].values.any?(&:positive?) || row[:follow_ups].positive? }
  end

  def untracked_reports
    @untracked_reports ||= days.reverse.flat_map do |entry|
      entry[:missing].reject { |row| row[:request_id] }.map { |row| row.merge(day: entry[:day]) }
    end
  end

  private

  def active
    ReconciliationFollowUp.active.where('period_from <= ? AND period_to >= ?', ending_on, starting_on)
  end

  def periods
    @periods ||= active.group(:period_from, :period_to).count
  end

  def requests
    @requests ||= active.where(category: 'missing_report', document_kind: 'register_control')
      .order(:due_on, :id).pluck(:period_from, :source, :currency, :location_id, :id)
      .each_with_object({}) { |(day, source, currency, location, id), result| result[[day, source, currency, location.presence]] ||= id }
  end
end
