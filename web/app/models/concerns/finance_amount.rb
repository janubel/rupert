# frozen_string_literal: true

# Exact dollar input for local finance records; never round malformed input.
module FinanceAmount
  extend ActiveSupport::Concern

  included do
    validate :validate_entered_amount
  end

  def amount
    return @entered_amount if defined?(@entered_amount)

    (BigDecimal(amount_cents.to_s) / 100).to_s('F') unless amount_cents.nil?
  end

  def amount=(value)
    @entered_amount = value.to_s.strip
    self.amount_cents = @entered_amount.match?(/\A\d{1,9}(?:\.\d{1,2})?\z/) ? (BigDecimal(@entered_amount) * 100).to_i : nil
  end

  private

  def validate_entered_amount
    return unless defined?(@entered_amount)
    return if @entered_amount.match?(/\A\d{1,9}(?:\.\d{1,2})?\z/)

    errors.add(:amount, 'must be a positive dollar amount with at most two decimal places')
  end
end
