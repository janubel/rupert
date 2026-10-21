# frozen_string_literal: true

require 'test_helper'

class ReportTableHelperTest < ActionView::TestCase
  include ReportTableHelper

  test 'previous and next move whole months, quarters and day spans by their own length' do
    assert_equal [Date.new(2026, 8, 1), Date.new(2026, 8, 31)], report_shift(Date.new(2026, 9, 1), Date.new(2026, 9, 30), -1)
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 31)], report_shift(Date.new(2026, 9, 1), Date.new(2026, 9, 30), 1)
    assert_equal [Date.new(2026, 4, 1), Date.new(2026, 6, 30)], report_shift(Date.new(2026, 7, 1), Date.new(2026, 9, 30), -1)
    assert_equal [Date.new(2025, 12, 1), Date.new(2025, 12, 31)], report_shift(Date.new(2026, 1, 1), Date.new(2026, 1, 31), -1)
    assert_equal [Date.new(2026, 2, 1), Date.new(2026, 2, 28)], report_shift(Date.new(2026, 1, 1), Date.new(2026, 1, 31), 1)
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 7)], report_shift(Date.new(2026, 10, 8), Date.new(2026, 10, 14), -1)
    assert_equal [Date.new(2026, 10, 9), Date.new(2026, 10, 9)], report_shift(Date.new(2026, 10, 8), Date.new(2026, 10, 8), 1)
  end

  test 'range labels read naturally' do
    assert_equal 'September 2026', report_range_label(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
    assert_equal 'Q3 2026', report_range_label(Date.new(2026, 7, 1), Date.new(2026, 9, 30))
    assert_equal 'Oct 8 – Oct 14, 2026', report_range_label(Date.new(2026, 10, 8), Date.new(2026, 10, 14))
    assert_equal 'Dec 28, 2025 – Jan 3, 2026', report_range_label(Date.new(2025, 12, 28), Date.new(2026, 1, 3))
  end
end
