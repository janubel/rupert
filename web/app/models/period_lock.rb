# frozen_string_literal: true

require 'digest'

# Month, quarter and year locks for historical books.
#
# Each row is an event, "lock" or "unlock", in an append-only, hash-chained
# ledger (the same design as BookApproval): every entry commits to the one
# before it, so an edited, removed or reordered row is detectable with
# .verify_chain. The latest event for a period decides whether it is locked.
#
# A lock stores a fingerprint and the totals of everything Rupert holds for the
# period (PeriodSnapshot), and retains a dated JSON archive as evidence. While
# locked, money-out records, bank-line decisions, day reviews, close packages
# and approvals dated inside the period cannot be added, changed or removed
# (LockedPeriodGuard). Source imports keep arriving, because the source is the
# truth; if they change a locked period, the fingerprint no longer matches and
# the desk says so. Unlocking needs a written reason and is itself recorded.
class PeriodLock < ApplicationRecord
  include TenantScoped

  encrypts :reason
  encrypts :summary_json

  GENESIS = ('0' * 64).freeze
  KINDS = %w[monthly quarterly yearly].freeze
  ACTIONS = %w[lock unlock].freeze
  KIND_LABELS = { 'monthly' => 'Month', 'quarterly' => 'Quarter', 'yearly' => 'Year' }.freeze
  Error = Class.new(StandardError)

  belongs_to :actor, class_name: 'User', optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :period_kind, inclusion: { in: KINDS }
  validates :period_from, :period_to, :fingerprint, :summary_json, :actor_name, :acted_at, :prev_hash, :entry_hash, presence: true
  validates :reason, length: { maximum: 4000 }
  validates :reason, presence: true, if: -> { action == 'unlock' }

  before_update { throw :abort }
  before_destroy { throw :abort }

  scope :chronological, -> { order(:id) }
  after_create { self.class.forget_request_events! }

  def lock? = action == 'lock'
  def summary = JSON.parse(summary_json)
  def label = self.class.label(period_kind, period_from)

  class << self
    def bounds(kind, date)
      day = date.is_a?(Date) ? date : Date.iso8601(date.to_s)
      case kind
      when 'monthly' then [day.beginning_of_month, day.end_of_month]
      when 'quarterly' then [day.beginning_of_quarter, day.end_of_quarter]
      when 'yearly' then [day.beginning_of_year, day.end_of_year]
      else raise Error, 'Choose a month, quarter or year.'
      end
    rescue Date::Error
      raise Error, 'Use a date in YYYY-MM-DD format.'
    end

    def label(kind, from)
      case kind
      when 'monthly' then from.strftime('%B %Y')
      when 'quarterly' then "Q#{((from.month - 1) / 3) + 1} #{from.year}"
      else from.year.to_s
      end
    end

    # Latest event per period, oldest period first.
    def latest_events
      chronological.to_a.group_by { |e| [e.period_kind, e.period_from] }.values.map(&:last).sort_by { |e| [e.period_from, e.period_to] }
    end

    def latest_for(kind, from) = where(period_kind: kind, period_from: from).chronological.last

    def active_locks = latest_events.select(&:lock?)

    # Every lock event for this workspace, read once per request or job (money
    # records check locks on every save). A new event clears it (after_create).
    def request_events
      cache = (Current.metadata[:period_lock_events] ||= {})
      cache[Current.tenant_id] ||= chronological.to_a
    end

    def forget_request_events!
      Current.metadata.delete(:period_lock_events)
    end

    # The narrowest active lock covering a date (or any day of a range).
    def lock_covering(first, last = first)
      return nil if first.blank? || last.blank?

      candidates = request_events.select { |e| e.period_from <= last && e.period_to >= first }
      candidates.group_by { |e| [e.period_kind, e.period_from] }.values.map(&:last).select(&:lock?)
        .min_by { |e| e.period_to - e.period_from }
    end

    def locked?(first, last = first) = !lock_covering(first, last).nil?

    def locked_message(lock)
      "#{lock.label} is locked (#{lock.actor_name}, #{lock.acted_at.in_time_zone.to_date.strftime('%b %-d, %Y')}). Unlock it on the Books desk, with a reason, before changing anything dated inside it."
    end

    # Records a lock or unlock under a per-workspace row lock so concurrent
    # writes cannot fork the chain. A lock also retains a JSON archive of the
    # period's totals as evidence.
    def record!(action:, kind:, date:, user:, reason: nil, request: nil)
      raise Error, 'An active workspace is required.' unless Current.tenant_id.present?
      raise Error, 'Choose lock or unlock.' unless ACTIONS.include?(action)

      from, to = bounds(kind, date)
      raise Error, 'Only a finished period can be locked.' if action == 'lock' && to >= Date.current

      transaction do
        Tenant.unscoped.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
        current = latest_for(kind, from)
        raise Error, "#{label(kind, from)} is already locked." if action == 'lock' && current&.lock?
        raise Error, "#{label(kind, from)} is not locked." if action == 'unlock' && !current&.lock?

        snapshot = PeriodSnapshot.new(from: from, to: to)
        archive = action == 'lock' ? retain_archive!(kind, from, to, snapshot, user) : nil
        previous = unscoped.where(tenant_id: Current.tenant_id).order(:id).last
        record = new(action: action, period_kind: kind, period_from: from, period_to: to,
          fingerprint: snapshot.fingerprint, summary_json: snapshot.totals.to_json, reason: reason.to_s.strip.presence,
          archive_document_id: archive&.id, actor: user, actor_name: user.display_name || user.email,
          acted_at: Time.current.utc.floor(6), ip: request&.remote_ip, user_agent: request&.user_agent.to_s.first(255).presence,
          prev_hash: previous&.entry_hash || GENESIS)
        record.entry_hash = record.expected_hash
        record.save!
        record
      end
    end

    # => { ok:, count:, broken_id:, reason: }
    def verify_chain
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
      { ok: false, count: count, broken_id: nil, reason: "Could not read the lock ledger (#{e.class.name})." }
    end

    private

    def retain_archive!(kind, from, to, snapshot, user)
      body = { version: 1, kind: kind, label: label(kind, from), from: from.iso8601, to: to.iso8601, timezone: Time.zone.name,
               generated_at: Time.current.utc.iso8601(6), fingerprint: snapshot.fingerprint, totals: snapshot.totals,
               note: 'Totals Rupert held when this period was locked. Source systems remain the originals.' }
      ReconciliationEvidence.retain!(bytes: JSON.pretty_generate(body), filename: "period-lock-#{kind}-#{from.iso8601}.json", source: 'rupert',
        kind: 'period_archive', from: from.iso8601, to: to.iso8601, metadata: { 'note' => "#{label(kind, from)} lock archive", 'fingerprint' => snapshot.fingerprint },
        actor: user)
    end
  end

  # True when the period's records still match what was locked.
  # Compares only the sections this lock recorded, so adding a new snapshot
  # section later does not make older locks look changed.
  def still_matches?
    snapshot = PeriodSnapshot.new(from: period_from, to: period_to)
    recorded = begin
      JSON.parse(summary_json.to_s)
    rescue JSON::ParserError
      nil
    end
    return snapshot.fingerprint == fingerprint unless recorded.is_a?(Hash)

    snapshot.fingerprint_for(recorded.keys) == fingerprint
  end

  def canonical
    [tenant_id, action, period_kind, period_from.iso8601, period_to.iso8601, fingerprint, summary_json, reason,
     archive_document_id, actor_id, actor_name, acted_at.utc.iso8601(6), ip, user_agent, prev_hash].to_json
  end

  def expected_hash = Digest::SHA256.hexdigest(canonical)
end
