# frozen_string_literal: true

# A single line from an uploaded bank statement awaiting a person's decision.
# Amounts are signed integer cents: negative is money out. Descriptions are
# encrypted at rest. Lines are never deleted; deciding records who and when.
class BankStatementLine < ApplicationRecord
  include TenantScoped
  include LockedPeriodGuard

  encrypts :description
  encrypts :review_note

  STATUSES = %w[pending recorded ignored matched].freeze
  # Plain-keyword hints only. A suggestion is never applied without a person choosing it.
  CATEGORY_HINTS = {
    'rent' => %w[rent lease], 'utilities' => %w[electric power water gas internet comcast verizon at&t],
    'insurance' => %w[insurance geico progressive], 'shipping' => %w[usps ups fedex dhl postage stamps.com pirate],
    'software' => %w[shopify square google adobe intuit quickbooks github slack zoom], 'marketing' => %w[facebook meta ads mailchimp klaviyo],
    'taxes' => %w[irs tax treasury], 'labor' => %w[payroll gusto adp], 'supplies' => %w[amazon staples uline walmart target home depot lowes]
  }.freeze

  belongs_to :decided_by, class_name: 'User', optional: true
  belongs_to :journal_entry, class_name: 'Finance::JournalEntry', optional: true
  guard_locked_period :posted_on

  validates :account_label, :posted_on, :description, :fingerprint, presence: true
  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
  validates :status, inclusion: { in: STATUSES }
  validate :journal_entry_not_already_matched

  scope :pending, -> { where(status: 'pending') }
  scope :flagged, -> { where(review_flag: true) }
  scope :matched, -> { where(status: 'matched') }
  scope :for_document, ->(id) { where(document_id: id).order(:line_no) }

  def money_out? = amount_cents.negative?
  def out_cents = -amount_cents
  def pending? = status == 'pending'
  def matched? = status == 'matched'
  def recorded_source? = expense_id.present? || vendor_payment_id.present?

  def review_category_label
    { 'processor_deposit' => 'Processor payout', 'owner_transfer' => 'Owner / personal transfer',
      'bank_fees' => 'Bank & processing fees', 'tax_liability' => 'Tax remittance',
      'needs_review' => 'Needs your review', 'unidentified_deposit' => 'Unidentified receipt',
      'non_expense' => 'Excluded from expenses', 'vendor_payment' => 'Vendor payment' }
      .fetch(review_category, review_category.to_s.humanize.presence || 'Uncategorized')
  end

  def suggested_category
    text = description.to_s.downcase
    CATEGORY_HINTS.find { |_, words| words.any? { |w| text.include?(w) } }&.first || 'other'
  end

  # Link this line to the ledger entry it reconciles to (F40). Records who and
  # when, like decide!, but does not create any money record.
  def match!(journal_entry:, user:)
    mapping = BankStatementAccount.find_by(account_label: account_label)
    unless mapping
      errors.add(:base, 'Choose the ledger account for this statement before matching.')
      raise ActiveRecord::RecordInvalid, self
    end
    mapping.with_lock do
      with_lock do
        protect_recorded_source!
        raise_if_ignored!
        journal_entry.with_lock do
          validate_bank_match!(journal_entry, mapping)
          update!(status: 'matched', journal_entry_id: journal_entry.id,
            decided_by: user, decided_by_name: user.display_name || user.email, decided_at: Time.current)
        end
      end
    end
  end

  def unmatch!(user:)
    with_lock do
      protect_recorded_source!
      raise_if_ignored!
      update!(status: 'pending', journal_entry_id: nil,
        decided_by: user, decided_by_name: user.display_name || user.email, decided_at: Time.current)
    end
  end

  def decide!(status:, user:, expense: nil, vendor_payment: nil, journal_entry: nil)
    protect_recorded_source!
    update!(status: status, decided_by: user, decided_by_name: user.display_name || user.email, decided_at: Time.current,
      expense_id: expense&.id, vendor_payment_id: vendor_payment&.id, journal_entry_id: journal_entry&.id, review_flag: false, reviewed_at: Time.current,
      review_category: expense&.category || (vendor_payment ? 'vendor_payment' : review_category.presence || 'non_expense'))
  end

  private

  def protect_recorded_source!
    return unless recorded_source?

    errors.add(:base, 'This bank line is linked to its recorded expense or vendor payment. Review that source record before changing its journal link.')
    raise ActiveRecord::RecordInvalid, self
  end

  # An ignored line (e.g. a confirmed duplicate) has been deliberately dropped
  # from reconciliation. Matching or clearing it here would silently resurrect
  # it, so require an explicit restore from the statement page first.
  def raise_if_ignored!
    return unless status == 'ignored'

    errors.add(:base, 'This line was ignored (for example as a duplicate). Restore it from the statement page before matching it.')
    raise ActiveRecord::RecordInvalid, self
  end

  # A statement line may only be reconciled to a posted entry, in the same
  # workspace, whose bank (Cash/Checking) movement equals the line's signed
  # amount. Sign convention matches the workbench: money-in is positive on both
  # the statement and the ledger (a debit to Cash); money-out is negative.
  def validate_bank_match!(entry, mapping)
    signed = entry.journal_lines.sum do |line|
      line.account_id == mapping.ledger_account_id ? line.debit_cents.to_i - line.credit_cents.to_i : 0
    end
    return if entry.status == 'posted' && entry.tenant_id == tenant_id && mapping.tenant_id == tenant_id &&
      mapping.account_label == account_label && mapping.ledger_account.active? && signed == amount_cents

    errors.add(:base, "That ledger entry does not reconcile to this line. Confirm a posted entry in this workspace whose selected account movement equals #{amount_cents} cents.")
    raise ActiveRecord::RecordInvalid, self
  end

  # One ledger entry backs at most one statement line. The partial unique index
  # is the DB backstop; this gives the operator a plain-language message first.
  def journal_entry_not_already_matched
    return if journal_entry_id.blank?
    return unless self.class.where.not(id: id).where(account_label: account_label, journal_entry_id: journal_entry_id).exists?

    errors.add(:journal_entry_id, 'is already matched to another statement line')
  end
end
