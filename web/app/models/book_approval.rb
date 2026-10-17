# frozen_string_literal: true

require 'digest'

# A person's dated sign-off that they looked at the books for a day or week.
# Append-only and hash-chained: each entry commits to the previous one, so an
# edited, removed or reordered row is detectable (see .verify_chain). The
# stored digest binds the approval to the exact evidence reviewed; if that
# evidence later changes, the approval is shown as "changed since approval".
class BookApproval < ApplicationRecord
  include TenantScoped

  encrypts :notes
  encrypts :summary_json

  GENESIS = ('0' * 64).freeze
  KINDS = %w[daily weekly].freeze
  STATUSES = %w[approved approved_with_exceptions needs_attention].freeze
  STATUS_LABELS = { 'approved' => 'Approved', 'approved_with_exceptions' => 'Approved with exceptions',
                    'needs_attention' => 'Needs attention' }.freeze

  belongs_to :approved_by, class_name: 'User', optional: true

  validates :period_kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :period_from, :period_to, :report_digest, :summary_json, :approved_by_name, :approved_at,
    :prev_hash, :entry_hash, presence: true
  validates :notes, length: { maximum: 4000 }
  validates :notes, presence: true, unless: -> { status == 'approved' }

  before_update { throw :abort }
  before_destroy { throw :abort }

  scope :for_period, ->(kind, from) { where(period_kind: kind, period_from: from) }
  scope :chronological, -> { order(:id) }

  def status_label = STATUS_LABELS.fetch(status, status)
  def summary = JSON.parse(summary_json)
  def approved? = %w[approved approved_with_exceptions].include?(status)

  # Records an approval under a per-workspace lock so concurrent approvals
  # cannot fork the chain. `at` is truncated to the stored microsecond
  # precision so the hash recomputes identically after a round trip.
  def self.record!(period:, status:, notes:, user:, request: nil)
    raise ArgumentError, 'An active workspace is required.' unless Current.tenant_id.present?

    transaction do
      Tenant.unscoped.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      previous = unscoped.where(tenant_id: Current.tenant_id).order(:id).last
      record = new(
        period_kind: period.kind, period_from: period.from, period_to: period.to, status: status,
        report_digest: period.digest, summary_json: period.summary.to_json, notes: notes.to_s.strip.presence,
        approved_by: user, approved_by_name: user.display_name || user.email, approved_at: Time.current.utc.floor(6),
        ip: request&.remote_ip, user_agent: request&.user_agent.to_s.first(255).presence,
        prev_hash: previous&.entry_hash || GENESIS
      )
      record.entry_hash = record.expected_hash
      record.save!
      record
    end
  end

  def canonical
    [tenant_id, period_kind, period_from.iso8601, period_to.iso8601, status, report_digest, summary_json,
     approved_by_id, approved_by_name, approved_at.utc.iso8601(6), ip, user_agent, notes, prev_hash].to_json
  end

  def expected_hash
    Digest::SHA256.hexdigest(canonical)
  end

  # => { ok:, count:, broken_id:, reason: }. Walks the workspace chain in order.
  def self.verify_chain
    expected_prev = GENESIS
    count = 0
    chronological.find_each do |entry|
      count += 1
      return { ok: false, count: count, broken_id: entry.id, reason: 'Entry no longer links to the one before it.' } unless entry.prev_hash == expected_prev
      return { ok: false, count: count, broken_id: entry.id, reason: 'Entry contents no longer match their recorded fingerprint.' } unless entry.entry_hash == entry.expected_hash

      expected_prev = entry.entry_hash
    end
    { ok: true, count: count }
  rescue StandardError => e
    { ok: false, count: count, broken_id: nil, reason: "Could not read the ledger (#{e.class.name})." }
  end
end
