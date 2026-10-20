# frozen_string_literal: true

require 'test_helper'

class PageGuidesTest < ActiveSupport::TestCase
  test 'for_path resolves the right guide by URL prefix' do
    assert_equal 'dashboard', PageGuides.for_path('/').key
    assert_equal 'sales', PageGuides.for_path('/sales').key
    assert_equal 'sales', PageGuides.for_path('/sales?source=square').key
    assert_equal 'sizes', PageGuides.for_path('/size_families').key
    assert_equal 'access_log', PageGuides.for_path('/access_logs').key
    assert_equal 'finance_accounts', PageGuides.for_path('/finance/accounts').key
    assert_equal 'finance', PageGuides.for_path('/finance').key
    assert_equal 'users', PageGuides.for_path('/users').key
    assert_equal 'inventory', PageGuides.for_path('/inventory').key
    assert_equal 'inventory_exceptions', PageGuides.for_path('/inventory_exceptions').key
    assert_equal 'inventory_exceptions', PageGuides.for_path('/inventory_exceptions?section=holds').key
    assert_equal 'inventory_counts', PageGuides.for_path('/inventory_counts/new').key
    assert_equal 'registers', PageGuides.for_path('/sales/pos_sessions').key
    assert_equal 'employees', PageGuides.for_path('/people/employees').key
    assert_equal 'leave', PageGuides.for_path('/people/leave_requests').key
    assert_equal 'projects', PageGuides.for_path('/projects/projects').key
    assert_equal 'kpis', PageGuides.for_path('/goals/kpis').key
    assert_nil PageGuides.for_path('/orders/123')
    assert_nil PageGuides.for_path('/login')
  end

  test 'exception page help describes review and coverage rather than inventory corrections' do
    guide = PageGuides.for_path('/inventory_exceptions')
    assert_equal PageGuides.for('inventory_exceptions'), guide
    assert_includes guide.summary, 'read-only'
    help_text = guide.sections.map { |section| section[:body] }.join(' ')
    assert_includes help_text, 'does not change stock'
    assert_includes help_text, 'bounded query results'
    assert_includes help_text, 'Unknown quantities'
    refute_includes help_text, 'one-click corrections'
    refute_includes help_text, 'Set to 0'
  end

  test 'every guide has sections and tips' do
    PageGuides.keys.each do |key|
      guide = PageGuides.for(key)
      assert guide.summary.present?, "#{key} missing summary"
      assert guide.sections.any?, "#{key} missing sections"
    end
  end
end
