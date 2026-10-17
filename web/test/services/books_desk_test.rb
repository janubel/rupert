# frozen_string_literal: true

require 'test_helper'

class BooksDeskTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'frames this week and last week around today' do
    saturday = Date.new(2026, 10, 17)
    desk = BooksDesk.new(today: saturday)
    assert_equal Date.new(2026, 10, 5), desk.focus_week
    assert_equal 5, desk.this_week_days.size
    assert_equal 7, desk.focus_days.size
    assert_nil desk.next_week
    assert_equal 6, desk.focus_days.first.stages.size
  end

  test 'days of the unfinished week wait for the weekly sign-off' do
    desk = BooksDesk.new(today: Date.new(2026, 10, 17))
    assert(desk.this_week_days.all? { |day| day.stages.last.state == :later })
    assert(desk.focus_days.all? { |day| day.stages.last.blocker == :week })
  end

  test 'quarterly and yearly money reports cover the whole period' do
    q = MoneyReconciliationReport.new(kind: 'quarterly', date: '2026-08-14')
    assert_equal [Date.new(2026, 7, 1), Date.new(2026, 9, 30)], [q.from, q.to]
    y = MoneyReconciliationReport.new(kind: 'yearly', date: '2026-08-14')
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 12, 31)], [y.from, y.to]
    assert_equal Date.new(2025, 12, 31), MoneyReconciliationReport.previous_period('yearly', today: Date.new(2026, 3, 2))
  end
end
