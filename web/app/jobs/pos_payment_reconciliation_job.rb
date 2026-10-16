# frozen_string_literal: true

class PosPaymentReconciliationJob < ApplicationJob
  queue_as :default
  def perform
    PosPaymentAttempt.unscoped.where(status: %w[submitting unknown]).where('submitted_at < ?', 1.minute.ago).limit(50).each do |attempt|
      next unless attempt.tenant&.status == 'active'
      Current.set(tenant: attempt.tenant) do
        Pos::CardPayment.reconcile!(attempt)
      rescue Pos::Error => e
        ActivityLogger.log('pos_payment_needs_review', subject: attempt, details: e.message)
      end
    end
  end
end
