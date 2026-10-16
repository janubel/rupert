# frozen_string_literal: true

module Pos
  class Quote
    def self.decorate!(quote, snapshot, demo: false)
      rows = snapshot.records.index_by { |row| row['id'] }
      tax = 0
      verified = true
      quote[:lines].each do |line|
        row = rows.fetch(line[:variant_id].to_s)
        rate = row['tax_rate_mbp']
        rate = 0 if demo && rate.nil?
        if !rate.is_a?(Integer) || !rate.between?(0, 10_000_000)
          verified = false
          line[:tax_cents] = nil
        else
          unit = (BigDecimal(line[:unit_price]) * 100).to_i
          # Native C-Trax lines are per unit, so round each unit before quantity.
          rates = row['tax_rates_mbp'].is_a?(Array) ? row['tax_rates_mbp'] : [rate]
          line[:tax_cents] = rates.sum { |r| (BigDecimal(unit.to_s) * r / 10_000_000).round(0, BigDecimal::ROUND_HALF_UP).to_i } * line[:quantity]
          tax += line[:tax_cents]
        end
      end
      quote[:subtotal_cents] = (BigDecimal(quote[:subtotal]) * 100).to_i
      quote[:tax_cents] = verified ? tax : nil
      quote[:tax_verified] = verified
      quote[:total_before_tip_cents] = verified ? quote[:subtotal_cents] + tax : nil
      quote[:stock_captured_at] = snapshot.captured_at.iso8601(6)
      quote[:checkout] = true
      quote[:preview] = !!demo
    end
  end
end
