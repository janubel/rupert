# frozen_string_literal: true

require 'digest'
module Pos
  class CardPayment
    def self.call(checkout, nonce:)
      raise Error, 'Demo card checkout does not accept real card tokens.' if checkout.demo?
      raise Error, 'Invalid payment token.' unless nonce.is_a?(String) && nonce.bytesize.between?(1, 4096) && !nonce.match?(/[\x00-\x20\x7f]/)
      setting = PosSetting.find_by!(location: checkout.location)
      raise Error, 'Card checkout is disabled or the gateway changed.' unless setting.card_enabled && setting.verified_at && checkout.gateway_id == setting.gateway_id && checkout.environment == setting.environment
      gateway = Gateway.new(setting)
      gateway.merchant
      attempt = nil
      checkout.with_lock do
        return checkout if checkout.paid? || checkout.unresolved?
        raise Error, 'Checkout is not ready for card payment.' unless checkout.tender == 'card' && %w[ready declined].include?(checkout.status) && checkout.pos_display_session.active?
        setting.lock!
        raise Error, 'Gateway setup changed. Check the payment before continuing.' unless setting.lock_version == gateway.version
        checkout.pos_session.lock!
        raise Error, 'This register is closed.' unless checkout.pos_session.status == 'open'
        digest = Digest::SHA256.hexdigest(nonce)
        raise Error, 'This card token was already submitted. Check payment status.' if PosPaymentAttempt.exists?(nonce_digest: digest)
        attempt = checkout.pos_payment_attempts.create!(invoice: "RP#{SecureRandom.hex(9)}", nonce_digest: digest, submitted_at: Time.current)
        checkout.update!(status: 'processing')
      end
      # No transaction spans a payment request. A timeout stays unresolved.
      doc = gateway.charge(attempt, nonce)
      response = doc['transactionResponse']
      if response.is_a?(Hash) && response['responseCode'].to_s == '2'
        checkout.with_lock do
          attempt.update!(status: 'declined', resolved_at: Time.current)
          checkout.update!(status: 'declined')
        end
      else
        id = response.is_a?(Hash) && response['transId'].to_s.match?(/\A[1-9][0-9]{0,29}\z/) ? response['transId'].to_s : nil
        attempt.update!(transaction_id: id, status: 'unknown')
        checkout.update!(status: 'unknown')
        reconcile!(attempt)
      end
      checkout.reload
    rescue Error
      if attempt
        attempt.update!(status: 'unknown') unless attempt.reload.status == 'paid'
        checkout.update!(status: 'unknown') unless checkout.reload.paid?
      end
      raise
    end

    def self.reconcile!(attempt)
      checkout = attempt.pos_checkout
      return if checkout.paid?
      setting = PosSetting.find_by!(location: checkout.location)
      raise Error, 'Gateway changed. Review the original payment account.' unless checkout.gateway_id == setting.gateway_id && checkout.environment == setting.environment
      gateway = Gateway.new(setting)
      gateway.merchant
      row = attempt.transaction_id ? gateway.detail(attempt.transaction_id) : gateway.find_transaction(attempt.invoice, since: [attempt.submitted_at - 1.hour, 30.days.ago].max)
      return unless row
      amount = row['authAmount']
      raise Error, 'Gateway payment does not match this checkout.' unless row.dig('order', 'invoiceNumber') == attempt.invoice && amount && BigDecimal(amount.to_s) * 100 == checkout.total_cents
      checkout.with_lock do
        return if checkout.paid?
        if %w[capturedPendingSettlement settledSuccessfully].include?(row['transactionStatus']) && row['responseCode'].to_s == '1' && row['transactionType'] == 'authCaptureTransaction'
          Checkout.finalize!(checkout, transaction_id: row['transId'].to_s)
          attempt.update!(status: 'paid', transaction_id: row['transId'].to_s, resolved_at: Time.current)
        elsif %w[declined voided expired failedReview].include?(row['transactionStatus'])
          attempt.update!(status: 'declined', resolved_at: Time.current)
          checkout.update!(status: 'declined')
        end
      end
    rescue ArgumentError
      raise Error, 'Gateway amount could not be verified.'
    end
  end
end
