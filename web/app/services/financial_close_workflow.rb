# frozen_string_literal: true

class FinancialCloseWorkflow
  CHECKS = { 'originals_checked' => 'Expected originals and covered dates checked',
    'bank_checked' => 'Bank funding, fees and timing checked or documented as exceptions',
    'retention_checked' => 'Retention and access requirements checked' }.freeze
  attr_reader :report, :attention

  def initialize(day: Date.yesterday.iso8601)
    @report = DailyMoneyReconciliation.new(day: day)
    @attention = ReconciliationAttention.new(report)
  end

  def day
    report.day
  end

  def review
    @review ||= report.latest_review
  end

  def review_current?
    review && review.report_digest == report.digest
  end

  def follow_ups
    @follow_ups ||= ReconciliationFollowUp.covering(day).includes(:owner).order(:due_on, :id).to_a
  end

  def open_follow_ups
    follow_ups.reject { |item| item.status == 'closed' }
  end

  def issues
    @issues ||= attention.counts.merge(open_follow_ups: open_follow_ups.size,
      coverage: report.register.coverage.values.sum,
      unconfirmed_imports: report.register.rows.map { |row| row[:source] }.uniq.count { |source| !report.register.source_freshness.dig(source, :finished_at) })
  end

  def clear_for_close?
    review_current? && review.status == 'reviewed' && issues.values.all?(&:zero?)
  end

  def evidence_payload
    @evidence_payload ||= { version: 1, day: day.iso8601, timezone: Time.zone.name,
      report_digest: report.digest, report: report.payload, issues: issues,
      review: review && { id: review.id, status: review.status, report_digest: review.report_digest, current: !!review_current?, notes: review.notes },
      originals: report.documents.map { |doc| { id: doc.id, filename: doc.filename, sha256: doc.sha256, source: doc.source, kind: doc.kind, from: doc.period_from, to: doc.period_to } },
      follow_ups: follow_ups.map { |item|
                    { id: item.id, version: item.lock_version, title: item.title, status: item.status, owner: item.owner&.display_name,
        due_on: item.due_on, document_id: item.document_id, notes: item.notes } },
      limitations: ['Tracked requests do not establish a complete list of expected reports.',
        'Order, gateway and deposit observations remain separate; bank verification is a reviewer responsibility.',
        'This is an operational evidence package, not a legal compliance certification.'],
      drive: RetentionDriveConnection.first&.connected? ? 'Connection configured; verify copy status separately' : 'Pending; originals retained in Rupert' }.deep_stringify_keys
  end

  def digest
    Digest::SHA256.hexdigest(evidence_payload.to_json)
  end

  def packages
    ReconciliationDocument.where(kind: 'close_package', period_from: day, period_to: day)
      .select(:id, :filename, :created_at, :metadata_json).order(id: :desc).limit(10)
  end

  def retain!(values, actor:)
    raise ReconciliationEvidence::Error, 'Reload the close workspace; evidence or follow-up progress changed.' unless values['workflow_digest'] == digest
    raise ReconciliationEvidence::Error, 'Record a review against the current report before retaining a close package.' unless review_current?
    raise ReconciliationEvidence::Error, 'Confirm each close checklist item.' unless CHECKS.keys.all? { |key| values[key] == '1' }
    note = values['notes'].to_s.strip
    raise ReconciliationEvidence::Error, 'Enter a closing explanation of 1 to 4000 characters.' unless note.length.between?(1, 4000)
    disposition = values['disposition']
    raise ReconciliationEvidence::Error, 'Choose complete or close with documented exceptions.' unless %w[complete with_exceptions].include?(disposition)
    if disposition == 'complete' && !clear_for_close?
      raise ReconciliationEvidence::Error, 'Outstanding checks remain. Resolve them or choose close with documented exceptions.'
    end

    ReconciliationDocument.transaction do
      report.documents.each { |doc| verify_original!(doc) }
      raise ReconciliationEvidence::Error, 'Evidence changed during verification. Reload before closing.' unless self.class.new(day: day.iso8601).digest == digest
      archive = report.archive!(actor: actor)
      snapshot = evidence_payload.merge('workflow_digest' => digest, 'daily_archive_id' => archive.id,
        'disposition' => disposition, 'checklist' => CHECKS.keys.to_h { |key| [key, true] }, 'closing_note' => note, 'reviewer_id' => actor.id)
      ReconciliationEvidence.retain!(bytes: snapshot.to_json, filename: "financial-close-#{day}.json", source: 'rupert', kind: 'close_package',
        from: day.iso8601, to: day.iso8601, metadata: { workflow_digest: digest, disposition: disposition, report_digest: report.digest }, actor: actor)
    end
  end

  private

  def verify_original!(doc)
    ReconciliationDocument.find(doc.id).original_bytes
  rescue RuntimeError, ArgumentError, ActiveRecord::Encryption::Errors::Decryption
    raise ReconciliationEvidence::Error, "Original evidence ##{doc.id} failed verification. No close package was saved."
  end
end
