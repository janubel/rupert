# frozen_string_literal: true

require 'test_helper'

class ProjectsGuideTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'guide-manager@example.test', role: 'manager', password: 'password123')
    @employee = User.create!(tenant: @tenant, email: 'guide-employee@example.test', role: 'employee', password: 'password123')
    @project = Projects::Project.create!(name: 'Private project planning', description: 'Confidential planning notes')
    @task = Projects::Task.create!(title: 'Other assigned task', project: @project, assignee: @manager)
  end

  teardown { Current.reset }

  test 'managers reach the guide from projects project details and both task views' do
    sign_in(@manager)
    [projects_projects_path, projects_project_path(@project), projects_tasks_path, projects_tasks_path(view: 'list')].each do |path|
      get path
      assert_response :success
      assert_select 'a[href=?]', projects_getting_started_path, text: 'Getting started'
    end
    get projects_getting_started_path
    assert_response :success
    assert_select 'h1', 'Getting started'
    assert_includes response.body, @tenant.name
    assert_select '#managers h2', 'For managers: create a project and assign work'
    assert_select 'a[href=?]', new_projects_project_path, text: 'New project'
    assert_select '#employees h2', 'For employees: find and update your work'
    assert_includes response.body, 'Each employee task needs an Assignee.'
    assert_not_includes response.body, @project.description
  end

  test 'employees reach their guide without gaining project or coworker access' do
    @employee.user_permissions.create!(tenant_id: @tenant.id, permission: '*', enabled: true)
    sign_in(@employee)
    [projects_tasks_path, projects_tasks_path(view: 'list')].each do |path|
      get path
      assert_response :success
      assert_select 'h1', 'My tasks'
      assert_select 'a[href=?]', projects_getting_started_path, text: 'Getting started'
    end
    get projects_getting_started_path, params: { project_id: @project.id, task_id: @task.id }
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select '#employees h2', 'For employees: find and update your work'
    assert_select '#managers', count: 0
    assert_select 'a[href=?]', new_projects_project_path, count: 0
    assert_select 'a[href=?]', projects_projects_path, count: 0
    assert_select 'a[href=?]', projects_tasks_path, text: 'Open My tasks'
    [@project.name, @project.description, @task.title].each { |secret| assert_not_includes response.body, secret }
    get projects_project_path(@project), as: :json
    assert_response :forbidden
    post move_projects_task_path(@task), params: { status: 'done' }, as: :json
    assert_response :not_found
  end

  test 'read only project users can read guidance without management shortcuts' do
    reader = User.create!(tenant: @tenant, email: 'guide-reader@example.test', role: 'reader', password: 'password123')
    reader.update_permission_overrides!(['projects.read'])
    sign_in(reader)
    get projects_getting_started_path
    assert_response :success
    assert_includes response.body, 'Your account has read-only project access.'
    assert_select '#managers', count: 0
    assert_select 'a[href=?]', new_projects_project_path, count: 0
  end

  test 'roles without task or project access cannot read the guide' do
    cashier = User.create!(tenant: @tenant, email: 'guide-cashier@example.test', role: 'cashier', password: 'password123')
    sign_in(cashier)
    get projects_getting_started_path
    assert_redirected_to root_path
  end

  test 'the guide requires sign in' do
    get projects_getting_started_path
    assert_redirected_to login_path
  end

  private

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end
end
