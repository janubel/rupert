# frozen_string_literal: true

require 'test_helper'

# Recording a KPI reading takes a free-text measurement time. Bad input must
# come back as a message on the KPI page, never as a 500.
class KpiReadingsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = User.create!(email: 'kpi-admin@example.com', password: 'password123', role: 'admin', name: 'Admin',
      tenant_id: @tenant.id)
    post login_path, params: { email: @admin.email, password: 'password123' }
    Current.tenant = @tenant
    @kpi = Goals::Kpi.create!(name: 'Weekly sales', unit: 'USD', target_value: 1000, direction: 'up', tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
  end

  test 'records a reading with a parseable time' do
    assert_difference -> { @kpi.readings.count }, 1 do
      post reading_goals_kpi_path(@kpi), params: { value: '42', measured_at: '2026-10-20 14:30' }
    end
    assert_redirected_to goals_kpi_path(@kpi)
    assert_equal Time.zone.parse('2026-10-20 14:30'), @kpi.readings.last.measured_at
  end

  test 'a blank time means now' do
    travel_to Time.zone.local(2026, 10, 20, 9, 15) do
      post reading_goals_kpi_path(@kpi), params: { value: '7', measured_at: '' }
    end
    assert_equal Time.zone.local(2026, 10, 20, 9, 15), @kpi.readings.last.measured_at
  end

  test 'an out-of-range date is reported instead of raising' do
    assert_no_difference -> { @kpi.readings.count } do
      post reading_goals_kpi_path(@kpi), params: { value: '42', measured_at: '2026-13-45' }
    end
    assert_redirected_to goals_kpi_path(@kpi)
    assert_match(/real date/, flash[:alert])
  end

  test 'unreadable text is reported instead of saving a blank time' do
    assert_no_difference -> { @kpi.readings.count } do
      post reading_goals_kpi_path(@kpi), params: { value: '42', measured_at: 'not a date' }
    end
    assert_redirected_to goals_kpi_path(@kpi)
    assert_match(/real date/, flash[:alert])
  end
end
