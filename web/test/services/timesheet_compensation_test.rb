# frozen_string_literal: true

require 'test_helper'

class TimesheetCompensationTest < ActiveSupport::TestCase
  test 'commission is 1% of credited sales and card bonus is $10 per redemption' do
    result = TimesheetCompensation.calculate(sales_cents: 120_000, card_redemptions: 3)
    assert_equal 120_000, result[:sales_cents]
    assert_equal 1200, result[:commission_cents]
    assert_equal 3, result[:card_redemptions]
    assert_equal 3000, result[:card_bonus_cents]
    assert_equal 4200, result[:total_cents]
  end

  test 'zero sales and redemptions yield zero compensation' do
    result = TimesheetCompensation.calculate(sales_cents: 0, card_redemptions: 0)
    assert_equal({ sales_cents: 0, commission_cents: 0, card_redemptions: 0, card_bonus_cents: 0, total_cents: 0 }, result)
  end

  test 'commission rounds to the nearest cent' do
    result = TimesheetCompensation.calculate(sales_cents: 12_345, card_redemptions: 1)
    assert_equal 123, result[:commission_cents]
    assert_equal 1123, result[:total_cents]
  end

  test 'nil inputs are treated as zero' do
    result = TimesheetCompensation.calculate(sales_cents: nil, card_redemptions: nil)
    assert_equal 0, result[:commission_cents]
    assert_equal 0, result[:card_bonus_cents]
    assert_equal 0, result[:total_cents]
  end
end
