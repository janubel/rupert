# frozen_string_literal: true

module Finance
  # One balanced accounting entry in the double-entry general ledger. Holds a
  # header (date, kind, memo, source) and its debit/credit lines. The header
  # carries no amount of its own; totals are always derived from the lines so a
  # header can never disagree with its postings.
  class JournalEntry < ApplicationRecord
    include TenantScoped
    include LockedPeriodGuard

    self.table_name = 'journal_entries'

    KINDS = %w[expense sale vendor_payment manual opening imported].freeze
    STATUSES = %w[posted void].freeze

    has_many :journal_lines, foreign_key: :journal_entry_id, inverse_of: :journal_entry, dependent: :restrict_with_exception

    validates :posted_on, presence: true
    validates :kind, presence: true, inclusion: { in: KINDS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    guard_locked_period :posted_on
    validate :lines_balance, on: :create
    validate :only_voiding_after_posting, on: :update
    # Prepended so it runs before the has_many restrict callback registered above.
    before_destroy(prepend: true) { raise ActiveRecord::ReadOnlyRecord, 'Journal entries are permanent; void the entry instead.' }

    scope :posted, -> { where(status: 'posted') }
    scope :for_source, ->(type, id) { where(source_type: type.to_s, source_id: id.to_s) }
    scope :in_range, ->(from, to) {
      scope = all
      scope = scope.where('posted_on >= ?', from) if from
      scope = scope.where('posted_on <= ?', to) if to
      scope
    }
    scope :recent, ->(limit = 100) { order(posted_on: :desc, id: :desc).limit(limit) }

    def debit_cents = journal_lines.sum { |l| l.debit_cents.to_i }
    def credit_cents = journal_lines.sum { |l| l.credit_cents.to_i }
    def balanced? = debit_cents == credit_cents && journal_lines.size >= 2
    def void? = status == 'void'

    # Build and persist a balanced entry in one transaction. `lines` is an array
    # of hashes: { account_id:, debit_cents:, credit_cents:, memo: }. Raises on
    # an unbalanced or single-sided set so callers never persist a broken entry.
    def self.post!(kind:, posted_on:, lines:, memo: nil, source_type: nil, source_id: nil, created_by: nil)
      entry = new(
        kind: kind,
        posted_on: posted_on,
        memo: memo,
        source_type: source_type&.to_s,
        source_id: source_id&.to_s,
        status: 'posted',
        created_by_id: created_by&.id
      )
      entry.journal_lines = lines.each_with_index.map do |line, index|
        JournalLine.new(
          account_id: line[:account_id],
          debit_cents: line[:debit_cents].to_i,
          credit_cents: line[:credit_cents].to_i,
          memo: line[:memo],
          position: index
        )
      end
      entry.save!
      entry
    end

    # Voiding keeps the row and its lines for audit but drops them from every
    # report (reports only read `posted` entries).
    def void!
      update!(status: 'void')
    end

    private

    # Once written, an entry's only permitted change is posted -> void.
    def only_voiding_after_posting
      changed_fields = changed - %w[status updated_at]
      errors.add(:base, "A posted journal entry cannot be edited (#{changed_fields.join(', ')}); void it and post a correction.") if changed_fields.any?
      return unless will_save_change_to_status?

      errors.add(:status, 'can only change from posted to void.') unless status_in_database == 'posted' && status == 'void'
    end

    def lines_balance
      return if journal_lines.empty? && new_record? == false # allow header-only during build

      if journal_lines.size < 2
        errors.add(:base, 'A journal entry needs at least two lines.')
      elsif debit_cents != credit_cents
        errors.add(:base, "Journal entry is out of balance: debits #{debit_cents} ≠ credits #{credit_cents}.")
      end
    end
  end
end
