# frozen_string_literal: true

require 'base64'
require 'digest'

class PurchaseReceipt < ApplicationRecord
  include TenantScoped
  include FinanceAmount

  MAX_BYTES = 10.megabytes
  STATUSES = %w[draft submitted approved rejected].freeze
  encrypts :content_base64, :notes
  belongs_to :submitted_by, class_name: 'User'
  has_many :events, class_name: 'PurchaseReceiptEvent', dependent: :restrict_with_exception
  attr_readonly :tenant_id, :submitted_by_id, :filename, :content_type, :byte_size, :sha256, :content_base64

  validates :tenant_id, :payee, :incurred_on, :filename, :sha256, :content_base64, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :currency, inclusion: { in: %w[USD] }
  validate -> { errors.add(:category, 'is not an active expense category') unless (category_changed? || new_record? ? Finance::ExpenseCategory.active_keys : Finance::ExpenseCategory.known_keys).include?(category) }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES }
  validates :payee, length: { maximum: 200 }
  validates :notes, length: { maximum: 4000 }
  validates :sha256, uniqueness: { scope: [:tenant_id, :submitted_by_id], message: 'was already uploaded by you' }
  validate :same_workspace
  validate :valid_purchase_date
  before_destroy { throw :abort }

  def self.visible_to(user)
    return none unless user&.active? && Current.tenant_id.present?

    user.can_review_receipts? ? all : where(submitted_by_id: user.id)
  end

  def original_bytes
    bytes = Base64.strict_decode64(content_base64)
    raise ReceiptWorkflow::Error, 'Receipt file integrity check failed.' unless bytes.bytesize == byte_size && Digest::SHA256.hexdigest(bytes) == sha256

    bytes
  end

  private

  def same_workspace
    errors.add(:submitted_by, 'must belong to this workspace') unless submitted_by&.tenant_id == tenant_id
  end

  def valid_purchase_date
    errors.add(:incurred_on, 'cannot be in the future') if incurred_on && incurred_on > Date.current
  end
end
