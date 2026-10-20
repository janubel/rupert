# frozen_string_literal: true

require 'test_helper'

class ProjectsTaskPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @other = Tenant.create!(name: 'Other task workspace', subdomain: 'task-policy-other')
    @employee = User.create!(tenant: @tenant, email: 'task-policy-employee@example.com', role: 'employee', password: 'password123')
  end

  teardown { Current.reset }

  test 'record authorization requires both workspace and assignment even for unscoped records' do
    own = Projects::Task.new(tenant: @tenant, assignee: @employee)
    others = Projects::Task.new(tenant: @tenant)
    foreign = Projects::Task.new(tenant: @other, assignee_id: @employee.id)
    assert Projects::TaskPolicy.new(@employee, own).index?
    assert Projects::TaskPolicy.new(@employee, own).update?
    [others, foreign].each do |task|
      policy = Projects::TaskPolicy.new(@employee, task)
      refute policy.update?
      refute policy.move?
      refute policy.transition?
    end
    refute Projects::TaskPolicy.new(@employee, own).create?
    refute Projects::TaskPolicy.new(@employee, own).destroy?
  end

  test 'scope enforces workspace and assignee even when caller supplies an unscoped relation' do
    own = Projects::Task.create!(tenant: @tenant, title: 'Own policy task', assignee: @employee)
    Projects::Task.create!(tenant: @tenant, title: 'Unassigned policy task')
    foreign = Projects::Task.create!(tenant: @other, title: 'Foreign policy task')
    foreign.update_columns(assignee_id: @employee.id)
    Current.tenant = @other
    scope = Projects::TaskPolicy::Scope.new(@employee, Projects::Task.unscoped).resolve
    assert_equal [own.id], scope.pluck(:id)
  end

  test 'inactive or workspace-less accounts and anonymous callers have no self-service access' do
    task = Projects::Task.new(tenant: @tenant, assignee: @employee)
    @employee.active = false
    refute Projects::TaskPolicy.new(@employee, task).index?
    refute Projects::TaskPolicy.new(@employee, task).update?
    assert_empty Projects::TaskPolicy::Scope.new(@employee, Projects::Task.unscoped).resolve
    @employee.active = true
    @employee.tenant = nil
    task.tenant = nil
    refute Projects::TaskPolicy.new(@employee, task).update?
    assert_empty Projects::TaskPolicy::Scope.new(@employee, Projects::Task.unscoped).resolve
    refute Projects::TaskPolicy.new(nil, task).update?
    assert_empty Projects::TaskPolicy::Scope.new(nil, Projects::Task.unscoped).resolve
  end
end
