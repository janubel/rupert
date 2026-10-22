# frozen_string_literal: true

require 'test_helper'

class TeamChatNumberCheckTest < ActiveSupport::TestCase
  def check(answer, *sources) = TeamChat::NumberCheck.call(answer, sources)

  test 'figures found in the tool results pass, others are returned as written' do
    tool = 'Yesterday: 2 orders, 214.83 USD gross. {"gross_cents":21483,"gross_change_percent":-89.1,"tax_cents":1289}'
    assert_empty check('Yesterday you took $214.83 from 2 orders, down 89.1% (tax $12.89).', tool)
    assert_equal ['$334.83', '53.7%'], check('Sales were $334.83, up 53.7%.', tool)
  end

  test 'cents read as dollars, rounding to whole dollars or thousands is fine' do
    assert_empty check('About $215 yesterday.', '{"gross_cents":21483}')
    assert_empty check('Roughly $28k this month.', '{"gross_cents":2820794}')
    assert_empty check('Year to date: $1.2 million.', '{"gross_cents":118000000}')
    assert_equal ['$29k'], check('Roughly $29k this month.', '{"gross_cents":2820794}')
    assert_empty check('Taxes were 1,289.00 USD.', 'tax 1289.00')
  end

  test 'numbers the person asked about count, and answers without figures have nothing to flag' do
    assert_empty check('Orders over $100: none.', 'Sean: any orders over $100?')
    assert_empty check('Sync is healthy.', '')
    assert_equal ['$5.00'], check('That costs $5.00.', '')
  end
end
