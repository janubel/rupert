# frozen_string_literal: true

require 'test_helper'

class CashForecastScenarioTest < ActiveSupport::TestCase
  def values
    { as_of: '2026-12-29', currency: 'USD', horizon: '4', opening: '-0.01', reserve: '0', basis: 'entered_balance', notes: '=Synthetic planning note',
      weeks: 4.times.to_h { |i| [i.to_s, { receipts: '1.01', payments: '0' }] } }
  end

  test 'opening shortfall and year boundary are explicit and CSV text cannot become a formula' do
    forecast = CashForecastScenario.new(values)
    assert_equal 0, forecast.first_shortfall[:week]
    assert_equal 1, forecast.shortfall_cents
    assert_equal Date.new(2026, 12, 30), forecast.rows.first[:from]
    assert_equal Date.new(2027, 1, 5), forecast.rows.first[:to]
    assert_equal 100, forecast.rows.first[:closing_cents]
    assert_equal 403, forecast.rows.last[:closing_cents]
    assert_includes forecast.csv, "'=Synthetic planning note"
  end

  test 'missing decimal and negative receipt assumptions are rejected rather than silently filled' do
    [values.merge(opening: ''), values.merge(opening: '1.001'), values.merge(horizon: '400'),
      values.deep_merge(weeks: { '0' => { receipts: '-1' } })].each do |invalid|
      assert_raises(ReconciliationEvidence::Error) { CashForecastScenario.new(invalid) }
    end
  end
end
