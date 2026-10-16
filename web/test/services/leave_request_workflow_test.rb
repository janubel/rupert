# frozen_string_literal: true

require 'test_helper'

class LeaveRequestWorkflowTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @worker = People::Employee.create!(first_name: 'Leave', last_name: 'Worker')
    @balance = @worker.leave_balances.create!(year: 2026, leave_type: 'vacation', accrued_hours: 80, used_hours: 8)
    @request = @worker.leave_requests.create!(leave_type: 'vacation', starts_on: '2026-11-02', ends_on: '2026-11-02', hours: 8)
  end
  teardown { Current.reset }

  test 'approval and cancellation change balances once even with stale objects and retries' do
    stale = People::LeaveRequest.find(@request.id)
    LeaveRequestWorkflow.change(@request, :approve)
    LeaveRequestWorkflow.change(stale, :approve)
    assert_equal 16, @balance.reload.used_hours
    LeaveRequestWorkflow.change(@request, :cancel)
    LeaveRequestWorkflow.change(stale, :cancel)
    assert_equal 8, @balance.reload.used_hours
  end

  test 'cancelling unapproved or denied leave never subtracts unrelated used hours' do
    LeaveRequestWorkflow.change(@request, :cancel)
    assert_equal 8, @balance.reload.used_hours
  end

  test 'approval without configured allowance does not invent an entitlement' do
    @balance.destroy!
    LeaveRequestWorkflow.change(@request, :approve)
    balance = @worker.leave_balances.find_by!(year: 2026, leave_type: 'vacation')
    assert_equal 0, balance.accrued_hours
    assert_equal 8, balance.used_hours
  end

  test 'self-service cancellation cannot reverse approval even after state changes' do
    worker_user = User.create!(tenant: Current.tenant, email: 'leave-self@example.com', role: 'employee', password: 'password123')
    @worker.update!(user: worker_user)
    LeaveRequestWorkflow.change(@request, :approve)
    Current.user = worker_user
    assert_equal false, LeaveRequestWorkflow.change(@request, :cancel, self_service: true)
    assert @request.reload.approved?
    assert_equal 16, @balance.reload.used_hours
    assert_raises(Pundit::NotAuthorizedError) { LeaveRequestWorkflow.change(@request, :cancel) }
  end
end
