# frozen_string_literal: true

require 'test_helper'

# daily_close: the store's in-person registers for chat, the same figures as the Daily close page.
class DailyCloseToolTest < ActiveSupport::TestCase
  Row = DailyCloseSummary::Row

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @token = TeamChat::Token.new(@user)
    @today = Date.current
  end

  teardown { Current.reset }

  def register(net:, cash: 1000, tips: 100, notes: nil)
    Row.new(label: 'SwipeSimple register', kind: 'swipesimple', currency: 'USD', gross: net + 500, refunds: 500, net: net,
      tax: nil, tips: tips, cash: cash, credit: net - cash, notes: notes)
  end

  def ctrax(net:)
    Row.new(label: 'Main Street (C-Trax)', kind: 'ctrax', currency: 'USD', gross: net, refunds: 0, net: net, tax: 120, tips: 0, cash: net, credit: 0)
  end

  def stub_days(rows_by_day)
    DailyCloseSummary.stubs(:new).returns(*rows_by_day.map { |rows| stub(rows: rows) })
  end

  def call(args = {}) = Mcp::Tools::DailyClose.new(token: @token).call(args)

  test 'each store is its own row with net, gross, cash, card, tax, refunds and tips; unknown stays unknown' do
    stub_days([[register(net: 83_750), ctrax(net: 11_065)]])
    data = call.data
    assert_equal [@today.iso8601, @today.iso8601], data.values_at(:from, :to)
    swipe, main = data[:stores]
    assert_equal ['SwipeSimple register', 83_750, 84_250, 1000, 82_750, nil, 100], swipe.values_at(:store, :net_cents, :gross_cents, :cash_cents, :card_cents, :tax_cents, :tips_cents)
    assert_equal 'Main Street (C-Trax)', main[:store]
    assert_includes data[:note], 'never add stores together'
    assert_includes call.text, 'SwipeSimple register: net'
  end

  test 'a range sums each store over its days only, and says which days are missing' do
    stub_days([[register(net: 1000)], [register(net: 2000), ctrax(net: 500)]])
    rows = call('from' => (@today - 1).iso8601, 'to' => @today.iso8601).data[:stores]
    swipe = rows.find { |row| row[:store] == 'SwipeSimple register' }
    main = rows.find { |row| row[:store] == 'Main Street (C-Trax)' }
    assert_equal [3000, 2], swipe.values_at(:net_cents, :days_with_data)
    assert_equal 500, main[:net_cents]
    assert(main[:notes].any? { |note| note.include?('No day stored for 1 of 2 days') })
  end

  test 'a store filter, future dates and long ranges' do
    stub_days([[register(net: 1000), ctrax(net: 500)]])
    assert_equal ['Main Street (C-Trax)'], call('store' => 'c-trax').data[:stores].pluck(:store)
    assert_raises(Mcp::ToolError) { call('from' => (@today + 1).iso8601) }
    assert_raises(Mcp::ToolError) { call('from' => (@today - 40).iso8601, 'to' => @today.iso8601) }
  end

  test 'the evidence certifies net sales for every store first and carries store notes as gaps' do
    stub_days([[register(net: 83_750, notes: 'The export does not report sales tax.'), ctrax(net: 11_065)]])
    outcome = call
    evidence = TeamChat::FinancialEvidence.build(tool: 'daily_close', data: outcome.data, arguments: {}, tenant_id: @user.tenant_id, invocation: 'call-1')
    facts = evidence['facts']
    assert_equal ['Store net sales (gross minus refunds; before tax and tips)'] * 2, facts.first(2).pluck('meaning')
    assert_equal %w[837.5 110.65], facts.first(2).pluck('value')
    assert_includes facts.first['source'], 'separate from online orders'
    assert(evidence['gaps'].any? { |gap| gap.include?('does not report sales tax') })
    assert_operator facts.size, :<=, 12
    kept = TeamChat::FinancialEvidence.checked_prose('The SwipeSimple register took $837.50 today and Main Street $110.65.', [evidence])
    assert kept
    assert_includes kept, '✓ Store net sales'
    assert_nil TeamChat::FinancialEvidence.checked_prose('The store made $948.15 today.', [evidence]), 'stores are never added together'
  end
end
