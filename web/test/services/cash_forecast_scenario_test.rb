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

  test 'blank weeks are listed for confirmation and invalid amounts name their field' do
    forecast = CashForecastScenario.new(values.deep_merge(weeks: { '1' => { payments: '' }, '2' => { receipts: nil } }))
    assert_equal [{ week: 2, field: 'payments' }, { week: 3, field: 'receipts' }], forecast.blank_entries
    assert_equal '2:payments,3:receipts', forecast.zero_confirmation_key
    assert_equal 0, forecast.rows[2][:receipts_cents]
    assert_not forecast.zeros_confirmed?(nil)
    assert_not forecast.zeros_confirmed?('2:payments')
    assert forecast.zeros_confirmed?('2:payments,3:receipts')
    assert CashForecastScenario.new(values).zeros_confirmed?(nil)
    assert_raises(ReconciliationEvidence::Error) { forecast.retain!(baseline_digest: 'x', actor: nil, zero_confirmation: '2:payments') }
    { values.deep_merge(weeks: { '3' => { payments: '1.001' } }) => 'forecast_weeks_3_payments',
      values.deep_merge(weeks: { '0' => { receipts: '-1' } }) => 'forecast_weeks_0_receipts',
      values.merge(opening: ' ') => 'forecast_opening', values.merge(reserve: 'x') => 'forecast_reserve',
      values.merge(as_of: '2026-02-30') => 'forecast_as_of', values.merge(notes: '') => 'forecast_notes' }.each do |invalid, field|
      error = assert_raises(CashForecastScenario::FieldError) { CashForecastScenario.new(invalid) }
      assert_equal field, error.field
    end
    error = assert_raises(CashForecastScenario::FieldError) { CashForecastScenario.new(values.deep_merge(weeks: { '3' => { payments: 'abc' } })) }
    assert_match(/\AWeek 4 payments: /, error.message)
  end

  test 'units keep exact cents for prefilled values' do
    assert_equal ['12.05', '-0.01', '0.00', nil, '1234567890.12'], [1205, -1, 0, nil, 123_456_789_012].map { |cents| CashForecastScenario.units(cents) }
  end
end
