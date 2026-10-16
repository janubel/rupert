# frozen_string_literal: true

class AuthorizeNetSaleLink < ApplicationRecord
  include TenantScoped
  belongs_to :authorize_net_transaction
  belongs_to :order, class_name: 'Core::Order'
  belongs_to :reviewed_by, class_name: 'User'
  belongs_to :revoked_by, class_name: 'User', optional: true
  encrypts :evidence_note
  attr_readonly :tenant_id, :authorize_net_transaction_id, :order_id, :reviewed_by_id, :evidence_note
  scope :active, -> { where(revoked_at: nil) }
  validates :evidence_note, length: { minimum: 10, maximum: 1000 }
  validate :same_workspace
  validate :matching_payment, on: :create
  before_destroy { throw :abort }

  def eligible_payment?
    payment = authorize_net_transaction
    return false unless payment.tenant_id == Current.tenant_id && order.tenant_id == Current.tenant_id && revoked_at.nil?
    return false unless payment.environment == 'production' && payment.currency.present? && payment.currency == order.currency
    return false unless %w[authCaptureTransaction priorAuthCaptureTransaction captureOnlyTransaction].include?(payment.transaction_type)
    return false unless %w[capturedPendingSettlement settledSuccessfully].include?(payment.payment_status)

    amount = payment.payment_status == 'settledSuccessfully' ? payment.settled_amount : payment.authorized_amount
    return false unless amount * 100 == order.gross_cents && order.gross_cents.to_i.positive?

    !AuthorizeNetTransaction.where(environment: payment.environment, gateway_id: payment.gateway_id,
      reference_transaction_id: payment.source_transaction_id, transaction_type: 'refundTransaction',
      payment_status: %w[refundPendingSettlement refundSettledSuccessfully]).exists?
  end

  private

  def same_workspace
    records = [authorize_net_transaction, order, reviewed_by, revoked_by].compact
    errors.add(:base, 'Payment, sale and reviewers must belong to the active workspace.') unless tenant_id == Current.tenant_id &&
      records.all? { |record| record.tenant_id == tenant_id }
  end

  def matching_payment
    return if errors.any? || authorize_net_transaction.nil? || order.nil?

    errors.add(:base, 'Match a production captured or settled charge with the same currency and full sale amount. Refunded, voided, partial and split payments need separate review.') unless eligible_payment?
  end
end
