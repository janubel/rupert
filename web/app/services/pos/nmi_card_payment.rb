# frozen_string_literal: true

require 'digest'

module Pos
  class NmiCardPayment
    def self.call(checkout, nonce:)
      raise Error, 'Demo card checkout does not accept real card tokens.' if checkout.demo?
      unless nonce.is_a?(String) && nonce.match?(/\A[A-Za-z0-9_-]{10,4096}\z/)
        raise Error, 'Invalid NMI payment token.'
      end
      gateway = gateway_for(checkout)
      gateway.merchant
      attempt = nil
      checkout.with_lock do
        return checkout if checkout.paid? || checkout.unresolved?
        unless checkout.tender == 'card' && %w[ready declined].include?(checkout.status) && checkout.pos_display_session.active?
          raise Error, 'Checkout is not ready for NMI sandbox payment.'
        end
        setting = PosSetting.lock.find_by!(location: checkout.location)
        raise Error, 'NMI setup changed. Check payment status.' unless setting.lock_version == gateway.version && setting.card_enabled && setting.verified_at
        digest = Digest::SHA256.hexdigest(nonce)
        raise Error, 'This card token was already submitted. Check payment status.' if PosPaymentAttempt.exists?(nonce_digest: digest)
        attempt = checkout.pos_payment_attempts.create!(invoice: "RN#{SecureRandom.hex(12)}", nonce_digest: digest, submitted_at: Time.current)
        checkout.update!(status: 'processing')
      end
      # A durable attempt exists before HTTP. Never hold a DB lock over a charge.
      response = gateway.charge(attempt, nonce)
      checkout.with_lock do
        return checkout if checkout.paid?
        if response['response'].to_s == '2'
          attempt.update!(status: 'declined', resolved_at: Time.current)
          checkout.update!(status: 'declined')
        else
          id = response['id'].to_s
          attempt.update!(status: 'unknown', transaction_id: id.match?(/\A[1-9][0-9]{0,29}\z/) ? id : nil)
          checkout.update!(status: 'unknown')
        end
      end
      reconcile!(attempt) unless checkout.status == 'declined'
      checkout.reload
    rescue Error
      if attempt
        checkout.with_lock do
          unless checkout.paid?
            attempt.update!(status: 'unknown')
            checkout.update!(status: 'unknown')
          end
        end
      end
      raise
    rescue ActiveRecord::RecordNotUnique
      raise Error, 'This card token was already submitted. Check payment status.'
    end

    def self.reconcile!(attempt)
      checkout = attempt.pos_checkout
      return if checkout.paid?
      gateway = gateway_for(checkout)
      gateway.merchant
      row = gateway.transaction(attempt)
      return unless row
      unless row['transaction_id'].match?(/\A[1-9][0-9]{0,29}\z/) && row['order_id'] == attempt.invoice &&
          row['currency'] == 'USD' && row['transaction_type'] == 'cc' &&
          (attempt.transaction_id.blank? || row['transaction_id'] == attempt.transaction_id)
        raise Error, 'NMI payment does not match this sandbox checkout.'
      end
      sales = row['actions'].select { |action| action['action_type'] == 'sale' }
      success = sales.one? && sales.first['success'] == '1' &&
        sales.first['amount'].match?(/\A\d{1,9}(?:\.\d{1,2})?\z/) &&
        BigDecimal(sales.first['amount']) * 100 == checkout.total_cents
      reversed = row['actions'].any? { |action| %w[void refund credit].include?(action['action_type']) && action['success'] == '1' }
      checkout.with_lock do
        return if checkout.paid?
        if success && !reversed && %w[pendingsettlement complete].include?(row['condition'])
          Checkout.finalize!(checkout, transaction_id: row['transaction_id'])
          attempt.update!(status: 'paid', transaction_id: row['transaction_id'], resolved_at: Time.current)
        elsif %w[failed canceled abandoned].include?(row['condition']) && !success
          attempt.update!(status: 'declined', transaction_id: row['transaction_id'], resolved_at: Time.current)
          checkout.update!(status: 'declined')
        else
          raise Error, 'NMI sandbox payment is unresolved. No new charge was sent.'
        end
      end
    end

    def self.gateway_for(checkout)
      setting = PosSetting.find_by!(location: checkout.location)
      gateway = NmiGateway.new(setting)
      gateway.assert_checkout!(checkout)
      raise Error, 'NMI sandbox checkout is disabled.' unless setting.card_enabled && setting.verified_at
      gateway
    end
    private_class_method :gateway_for
  end
end
