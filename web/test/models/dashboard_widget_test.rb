# frozen_string_literal: true

require 'test_helper'

class DashboardWidgetTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
  end

  teardown { Current.tenant = nil }

  test 'default_order lists all widgets' do
    assert_equal 10, DashboardWidget.default_order.length
    assert_equal %w[stats today_channels revenue cash_flow attention stock_alerts sync_history goals commissions people],
      DashboardWidget.default_order
  end

  test 'default layout prioritizes sales and avoids duplicate stock alert history' do
    entries = DashboardWidget.entries({})
    assert_equal(DashboardWidget.default_order, entries.map { |widget, _| widget.key })
    assert_equal ['stock_alerts'], entries.reject { |_, visible| visible }.map { |widget, _| widget.key }
  end

  test 'entries honors saved order and hidden set, appending unknown widgets' do
    entries = DashboardWidget.entries({
                                        'widgets' => %w[revenue stats sync_history],
                                        'hidden' => ['stats']
                                      })
    assert_equal(%w[revenue stats sync_history today_channels cash_flow attention stock_alerts goals commissions people],
      entries.map { |widget, _| widget.key })
    visible = entries.select { |_, v| v }.map { |widget, _| widget.key }
    assert_includes visible, 'revenue'
    refute_includes visible, 'stats'
  end

  test 'user serializes dashboard_config to json' do
    @user.update!(dashboard_config: { 'widgets' => %w[stats revenue], 'hidden' => ['attention'] })
    @user.reload
    assert_equal({ 'widgets' => %w[stats revenue], 'hidden' => ['attention'] }, @user.dashboard_config_hash)
  end

  test 'dashboard_config_hash defaults to empty hash' do
    @user.update!(dashboard_config: nil)
    assert_equal({}, @user.dashboard_config_hash)
  end
end
