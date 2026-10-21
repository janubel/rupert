# frozen_string_literal: true

require 'test_helper'

class TimeRangePickerTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 20) # a Tuesday; its pay week began Thursday Oct 15

  def dates(key)
    preset = TimeRangePicker.preset(key, TODAY)
    [preset.from, preset.to]
  end

  test 'named ranges use Thursday–Wednesday pay weeks and Monday–Sunday weeks' do
    assert_equal %w[today yesterday this_pay_week last_pay_week next_pay_week this_week last_week this_month last_month
      this_quarter last_quarter year_to_date last_year], TimeRangePicker.presets(TODAY).map(&:key)
    assert_equal [Date.new(2026, 10, 20)] * 2, dates('today')
    assert_equal [Date.new(2026, 10, 19)] * 2, dates('yesterday')
    assert_equal [Date.new(2026, 10, 15), Date.new(2026, 10, 21)], dates('this_pay_week')
    assert_equal [Date.new(2026, 10, 8), Date.new(2026, 10, 14)], dates('last_pay_week')
    assert_equal [Date.new(2026, 10, 22), Date.new(2026, 10, 28)], dates('next_pay_week')
    assert_equal [Date.new(2026, 10, 19), Date.new(2026, 10, 25)], dates('this_week')
    assert_equal [Date.new(2026, 10, 12), Date.new(2026, 10, 18)], dates('last_week')
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 31)], dates('this_month')
    assert_equal [Date.new(2026, 9, 1), Date.new(2026, 9, 30)], dates('last_month')
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 12, 31)], dates('this_quarter')
    assert_equal [Date.new(2026, 7, 1), Date.new(2026, 9, 30)], dates('last_quarter')
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 10, 20)], dates('year_to_date')
    assert_equal [Date.new(2025, 1, 1), Date.new(2025, 12, 31)], dates('last_year')
    TimeRangePicker.presets(TODAY).select { |preset| preset.key.end_with?('pay_week') }.each do |preset|
      assert preset.from.thursday?
      assert preset.to.wednesday?
    end
  end

  test 'resolves a preset, custom dates, blanks and the no-JavaScript form' do
    resolve = ->(params) { TimeRangePicker.resolve(ActionController::Parameters.new(params), today: TODAY) }
    assert_equal [Date.new(2026, 10, 8), Date.new(2026, 10, 14), 'last_pay_week'], resolve.call(range: 'last_pay_week').to_h.values
    custom = resolve.call(range: 'custom', from: '2026-10-02', to: '2026-10-09')
    assert_equal [Date.new(2026, 10, 2), Date.new(2026, 10, 9), 'custom'], custom.to_h.values
    assert_equal 'this_month', resolve.call(from: '2026-10-01', to: '2026-10-31').key
    assert_equal [nil, nil, 'all'], resolve.call({}).to_h.values
    assert_equal [nil, nil, 'all'], resolve.call(range: 'all', from: '', to: '', range_shown: '..').to_h.values
    # Without JavaScript: dropdown changed, dates left as shown -> the preset applies.
    shown = { range_shown: '2026-10-01..2026-10-31', from: '2026-10-01', to: '2026-10-31' }
    assert_equal 'next_pay_week', resolve.call(shown.merge(range: 'next_pay_week')).key
    # Without JavaScript: dates edited, dropdown left on the shown preset -> the dates apply.
    edited = resolve.call(shown.merge(range: 'this_month', to: '2026-10-10'))
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 10), 'custom'], edited.to_h.values
    assert_equal 'custom', resolve.call(range: 'nonsense', from: '2026-10-02', to: '2026-10-03').key
    assert_raises(Date::Error) { resolve.call(from: 'not-a-date') }
    assert_equal 'custom', TimeRangePicker.key_for(Date.new(2026, 10, 1), nil, TODAY)
  end
end
