# frozen_string_literal: true

require 'test_helper'

class ScheduleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'schedule-worker@example.com', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Alex', last_name: 'Planned', user: @user)
    @other = People::Employee.create!(first_name: 'Someone', last_name: 'Else')
    @monday = Date.new(2026, 10, 19)
    @mine = @worker.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours, role_label: 'Counter', notes: 'Bring keys')
    @other.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours, role_label: 'PRIVATEOTHER')
  end
  teardown { Current.reset }

  def sign_in(user, password)
    post login_path, params: { email: user.email, password: password }
    Current.tenant = @tenant
  end

  test 'employee sees only their own planned shifts for the chosen week' do
    sign_in(@user, 'password123')
    get employee_schedule_path(week: '2026-10-22')
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'nav[aria-label="My workspace"] a[href=?]', employee_schedule_path
    assert_includes response.body, '9:00 AM – 5:00 PM'
    assert_includes response.body, 'Counter'
    assert_includes response.body, 'Bring keys'
    refute_includes response.body, 'PRIVATEOTHER'
    get employee_schedule_path(week: '2026-10-26')
    assert_includes response.body, 'No shift planned'
    refute_includes response.body, 'Counter'
    get employee_schedule_path(week: 'nonsense')
    assert_redirected_to employee_app_path
  end

  test 'schedule rejects overlaps, reversed times and other-workspace people' do
    overlap = @worker.scheduled_shifts.new(starts_at: @monday.in_time_zone + 16.hours, ends_at: @monday.in_time_zone + 20.hours)
    refute overlap.valid?
    assert_includes overlap.errors.full_messages.to_sentence, 'overlaps'
    refute @worker.scheduled_shifts.new(starts_at: @monday.in_time_zone + 20.hours, ends_at: @monday.in_time_zone + 19.hours).valid?
    refute @worker.scheduled_shifts.new(starts_at: @monday.in_time_zone + 30.hours, ends_at: @monday.in_time_zone + 60.hours).valid?
  end

  test 'administrators plan, edit and remove shifts' do
    admin = users(:regular_user)
    sign_in(admin, 'password')
    get people_scheduled_shifts_path(week: '2026-10-19')
    assert_response :success
    assert_includes response.body, 'Alex Planned'
    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-20T10:00', ends_at: '2026-10-20T14:00', role_label: 'Stock' } }
    end
    assert_response :redirect
    shift = People::ScheduledShift.order(:id).last
    get edit_people_scheduled_shift_path(shift)
    assert_response :success
    patch people_scheduled_shift_path(shift), params: { scheduled_shift: { role_label: 'Floor' } }
    assert_equal 'Floor', shift.reload.role_label
    assert_difference 'People::ScheduledShift.count', -1 do
      delete people_scheduled_shift_path(shift)
    end
  end

  test 'managers can plan shifts; shift leaders only once granted schedule editing' do
    manager = User.create!(tenant: @tenant, email: 'schedule-manager@example.com', password: 'password123', role: 'manager')
    sign_in(manager, 'password123')
    get people_scheduled_shifts_path(week: '2026-10-19')
    assert_response :success
    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-21T10:00', ends_at: '2026-10-21T14:00' } }
    end
    delete logout_path

    leader = User.create!(tenant: @tenant, email: 'schedule-leader@example.com', password: 'password123', role: 'shift_leader')
    sign_in(leader, 'password123')
    assert_no_difference 'People::ScheduledShift.count' do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-22T10:00', ends_at: '2026-10-22T14:00' } }
    end
    refute_includes ModuleRegistry.nav_for(leader).map(&:key), 'schedule'
    leader.user_permissions.create!(tenant_id: @tenant.id, permission: 'schedule.write', enabled: true)
    assert_includes ModuleRegistry.nav_for(leader.reload).map(&:key), 'schedule'
    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-22T10:00', ends_at: '2026-10-22T14:00' } }
    end
  end

  test 'the Employee app shows the next planned shift' do
    travel_to @monday.in_time_zone + 8.hours
    sign_in(@user, 'password123')
    get employee_app_path
    assert_response :success
    assert_select '.card-title', 'Next shift'
    assert_includes response.body, 'Today · 9:00 AM – 5:00 PM · Counter'
    travel_to @monday.in_time_zone + 18.hours
    get employee_app_path
    assert_includes response.body, 'No shift planned yet.'
  end

  test 'employees cannot open the manager schedule' do
    sign_in(@user, 'password123')
    get people_scheduled_shifts_path
    refute_equal 200, response.status
    assert_no_difference 'People::ScheduledShift.count' do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-21T10:00', ends_at: '2026-10-21T14:00' } }
    end
  end
end
