# frozen_string_literal: true

require 'test_helper'

class FinanceHelperTest < ActionView::TestCase
  include FinanceHelper

  test 'formats large amounts with delimiters and exactly two decimals' do
    assert_equal '$1,234,567.89', finance_money_text(123_456_789)
    assert_equal '$0.05', finance_money_text(5)
  end

  test 'negative amounts use a real minus sign and the negative class' do
    assert_equal '−$0.01', finance_money_text(-1)
    html = finance_money(-1)
    assert_includes html, '−$0.01'
    assert_includes html, 'money-negative'
    assert_includes html, 'class="money money-negative"'
  end

  test 'a missing value is a dash, never zero dollars' do
    assert_equal '—', finance_money_text(nil)
    assert_includes finance_money(nil), 'money-missing'
    assert_not_includes finance_money(nil), '$0.00'
    assert_equal 'Unknown', finance_money_text(nil, missing: 'Unknown')
  end

  test 'a real zero is shown as zero unless the column asks for a dash' do
    assert_equal '$0.00', finance_money_text(0)
    assert_equal '—', finance_money_text(0, zero: :dash)
  end

  test 'non-USD and unknown currencies are labelled, never shown as dollars' do
    assert_equal 'CAD 5.00', finance_money_text(500, currency: 'CAD')
    assert_equal 'Unknown currency 5.00', finance_money_text(500, currency: nil)
  end

  test 'balance status states the difference in words' do
    assert_includes finance_balance_status(0), 'Balanced'
    bad = finance_balance_status(-250)
    assert_includes bad, 'Out of balance by $2.50'
    assert_includes bad, 'role="status"'
  end

  test 'csv_safe neutralises spreadsheet formulas' do
    %w[=SUM(A1) +1 -1 @cmd].each do |value|
      assert_equal "'#{value}", FinanceHelper.csv_safe(value)
    end
    assert_equal 'Plain', FinanceHelper.csv_safe('Plain')
  end
end
