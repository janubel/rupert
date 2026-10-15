# frozen_string_literal: true

require 'bigdecimal'

# Canonical ledger precision is one milligram. Decimal unit conversions round
# half-up once at the boundary; balances and all arithmetic are integer mg.
class BulkMass
  MAX_MG = 9_223_372_036_854_775_807
  FACTORS = {
    'mg' => BigDecimal('1'),
    'g' => BigDecimal('1000'),
    'kg' => BigDecimal('1000000'),
    'oz' => BigDecimal('28349.523125'),
    'lb' => BigDecimal('453592.37')
  }.freeze

  def self.convert(quantity, unit, signed: false)
    text = quantity.to_s.strip
    unless text.length <= 40 && text.match?(/\A[+-]?\d+(?:\.\d+)?\z/) && FACTORS.key?(unit)
      raise ArgumentError, 'Enter a decimal weight and a supported mass unit.'
    end

    decimal = BigDecimal(text)
    raise ArgumentError, 'Weight must be positive.' if !signed && decimal <= 0

    milligrams = (decimal * FACTORS.fetch(unit)).round(0, BigDecimal::ROUND_HALF_UP).to_i
    raise ArgumentError, 'Weight must be at least one milligram after rounding.' if milligrams.zero?
    raise ArgumentError, 'Weight exceeds the supported range.' if milligrams.abs > MAX_MG

    [milligrams, decimal.to_s('F')]
  end
end
