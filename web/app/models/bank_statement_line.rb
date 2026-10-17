# frozen_string_literal: true

# A single line from an uploaded bank statement awaiting a person's decision.
# Amounts are signed integer cents: negative is money out. Descriptions are
# encrypted at rest. Lines are never deleted; deciding records who and when.
class BankStatementLine < ApplicationRecord
  include TenantScoped

  encrypts :description

  STATUSES = %w[pending recorded ignored].freeze
  # Plain-keyword hints only. A suggestion is never applied without a person choosing it.
  CATEGORY_HINTS = {
    'rent' => %w[rent lease], 'utilities' => %w[electric power water gas internet comcast verizon at&t],
    'insurance' => %w[insurance geico progressive], 'shipping' => %w[usps ups fedex dhl postage stamps.com pirate],
    'software' => %w[shopify square google adobe intuit quickbooks github slack zoom], 'marketing' => %w[facebook meta ads mailchimp klaviyo],
    'taxes' => %w[irs tax treasury], 'labor' => %w[payroll gusto adp], 'supplies' => %w[amazon staples uline walmart target home depot lowes]
  }.freeze

  belongs_to :decided_by, class_name: 'User', optional: true

  validates :account_label, :posted_on, :description, :fingerprint, presence: true
  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending') }
  scope :for_document, ->(id) { where(document_id: id).order(:line_no) }

  def money_out? = amount_cents.negative?
  def out_cents = -amount_cents
  def pending? = status == 'pending'

  def suggested_category
    text = description.to_s.downcase
    CATEGORY_HINTS.find { |_, words| words.any? { |w| text.include?(w) } }&.first || 'other'
  end

  def decide!(status:, user:, expense: nil, vendor_payment: nil)
    update!(status: status, decided_by: user, decided_by_name: user.display_name || user.email, decided_at: Time.current,
      expense_id: expense&.id, vendor_payment_id: vendor_payment&.id)
  end
end
