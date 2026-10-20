# frozen_string_literal: true

require 'test_helper'

class MoneyTest < ActiveSupport::TestCase
  test 'decimal strings convert exactly, never through a Float' do
    assert_equal 29, Money.cents_from_amount('0.29')
    assert_equal 6360, Money.cents_from_amount('63.60')
    assert_equal 123_450, Money.cents_from_amount('$1,234.50')
    assert_equal 5, Money.cents_from_amount('0.05')
    assert_equal 1_999_999_999_99, Money.cents_from_amount('1999999999.99')
    assert_equal(-250, Money.cents_from_amount('-2.50'))
    assert_equal 1000, Money.cents_from_amount(10)
    assert_equal 1299, Money.cents_from_amount(12.99), 'a float column value re-reads through its shortest decimal form'
    assert_equal 1299, Money.cents_from_amount(BigDecimal('12.99'))
  end

  test 'half-cent inputs round half up and do not collapse to a nearby float' do
    # 1.005 as a Float is 1.00499999999999989…; the decimal path must say 101.
    assert_equal 101, Money.cents_from_amount(BigDecimal('1.005'))
    assert_equal 101, Money.cents_from_amount(1.005)
  end

  test 'blank or malformed input is nil in the lenient form and raises in the strict form' do
    assert_nil Money.cents_from_amount(nil)
    assert_nil Money.cents_from_amount('')
    assert_nil Money.cents_from_amount('abc')
    assert_nil Money.cents_from_amount('1.234')
    assert_nil Money.cents_from_amount('1e5')
    assert_nil Money.cents_from_amount(Float::NAN)
    error = assert_raises(ArgumentError) { Money.cents_from_amount!('twelve', field: 'Refund amount') }
    assert_includes error.message, 'Refund amount'
    assert_equal 1200, Money.cents_from_amount!('12')
  end

  test 'cents format back to a two-decimal string without Float formatting' do
    assert_equal '0.05', Money.format_cents(5)
    assert_equal '12.30', Money.format_cents(1230)
    assert_equal '-2.50', Money.format_cents(-250)
    assert_equal '1999999999.99', Money.format_cents(199_999_999_999)
    assert_equal BigDecimal('12.34'), Money.amount_from_cents(1234)
  end
end
