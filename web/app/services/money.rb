# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/util'

# Money is integer cents everywhere in Rupert. This module is the only place
# that converts between decimal amounts (platform JSON strings, form fields,
# CSV cells) and cents, and it never goes through a binary Float: "0.29" must
# be 29 cents, not 28.999999999999996 rounded by luck.
module Money
  # Dollars, commas, whitespace and an optional sign; at most two decimals.
  AMOUNT = /\A[+-]?\d{1,12}(?:\.\d{1,2})?\z/

  # Convert a money amount to integer cents. Accepts a Shopify-style decimal
  # string ("63.60"), a Square CSV cell ("$1,234.50"), a BigDecimal, an
  # Integer or a Float that came from a float column. Returns +nil+ when the
  # amount is blank or not a plain decimal number.
  def self.cents_from_amount(amount)
    decimal = to_decimal(amount)
    return if decimal.nil?

    (decimal * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
  end

  # Like cents_from_amount but raises ArgumentError for blank or malformed
  # input. Use this for anything a person typed (refund amounts, opening cash).
  def self.cents_from_amount!(amount, field: 'amount')
    cents = cents_from_amount(amount)
    raise ArgumentError, "#{field} must be a plain number with up to two decimals" if cents.nil?

    cents
  end

  # Integer cents -> BigDecimal amount (12.34). Never a Float.
  def self.amount_from_cents(cents)
    BigDecimal(cents.to_i) / 100
  end

  # Integer cents -> "12.34" string for display/CSV without Float formatting.
  def self.format_cents(cents)
    amount = amount_from_cents(cents)
    sign = amount.negative? ? '-' : ''
    whole, frac = amount.abs.to_s('F').split('.')
    "#{sign}#{whole}.#{(frac || '').ljust(2, '0')[0, 2]}"
  end

  def self.to_decimal(amount)
    case amount
    when nil then nil
    when BigDecimal then amount
    when Integer then BigDecimal(amount)
    when Float then amount.finite? ? BigDecimal(amount.to_s) : nil
    else
      cleaned = amount.to_s.gsub(/[$,\s]/, '')
      return if cleaned.blank? || !cleaned.match?(AMOUNT)

      BigDecimal(cleaned)
    end
  end
  private_class_method :to_decimal
end
