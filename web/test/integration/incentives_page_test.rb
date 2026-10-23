# frozen_string_literal: true

require 'test_helper'

class IncentivesPageTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @worker = People::Employee.create!(user: @user, first_name: 'Model', last_name: 'Worker', employment_type: 'part_time')
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: @worker.employment_type, started_at: 3.days.ago.change(hour: 9),
      ended_at: 3.days.ago.change(hour: 12), request_token: SecureRandom.uuid)
  end

  teardown { Current.reset }

  test 'payroll readers see the model with the plan from the address' do
    post login_path, params: { email: @user.email, password: 'password' }
    get people_incentives_path(period: 'custom', from: 7.days.ago.to_date, to: Date.current, shift_rate: '1.5', trainees: [@worker.id])
    assert_response :success
    assert_select 'h1', 'Incentives model'
    assert_select 'th[scope=row]', text: @worker.name
    assert_select 'input[name=shift_rate][value=?]', '1.5'
    assert_select "input[name='trainees[]'][value=?][checked]", @worker.id.to_s
  end

  test 'staff without payroll access cannot open it' do
    employee = User.create!(tenant: Current.tenant, email: 'incentives-employee@example.com', role: 'employee', password: 'password123')
    post login_path, params: { email: employee.email, password: 'password123' }
    get people_incentives_path
    assert_includes [302, 303, 403, 404], response.status
  end
end
