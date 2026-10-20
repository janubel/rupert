# frozen_string_literal: true

require 'test_helper'

# Tasks tab: every task across projects, filterable by status, with transitions.
class TasksFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'tasks@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'tasks@example.com', password: 'password123' }

    @project = Projects::Project.create!(name: 'Cleanup', tenant_id: @tenant.id)
    @task = Projects::Task.create!(project: @project, title: 'Fix duplicate SKUs', priority: 'high',
      tenant_id: @tenant.id)
  end

  def get_page(path, params: {})
    get(path, params: params.merge(shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host'))
  end

  # CurrentAttributes reset after each request; re-establish for direct queries.
  def as_user
    Current.user = @user
    Current.tenant = @tenant
  end

  def task_now
    as_user
    @task.reload
  end

  PARAMS = { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }.freeze

  test 'tasks index shows a board with the task in its column' do
    get_page projects_tasks_path
    assert_response :success
    assert_select 'h1', /Tasks/
    assert_select "[data-controller='task-board']"
    assert_select "section[data-status='todo'] article[data-task-id='#{@task.id}']", /Fix duplicate SKUs/
    assert_select "section[data-status='todo'] article", /Cleanup/
  end

  test 'tasks list view shows the task with its status' do
    get_page projects_tasks_path, params: { view: 'list' }
    assert_response :success
    assert_select 'p', /Fix duplicate SKUs/
    assert_select 'span', /To do/
  end

  test 'tasks index filters by status' do
    get_page projects_tasks_path, params: { status: 'done' }
    assert_response :success
    assert_select 'article', count: 0
  end

  test 'tasks index filters by search, priority, overdue and mine' do
    Projects::Task.create!(project: @project, title: 'Late thing', priority: 'urgent', due_on: Date.current - 3,
      assignee_id: @user.id, tenant_id: @tenant.id)

    get_page projects_tasks_path, params: { q: 'late' }
    assert_select 'article', count: 1
    get_page projects_tasks_path, params: { priority: 'high' }
    assert_select 'article', /Fix duplicate SKUs/
    assert_select 'article', count: 1
    get_page projects_tasks_path, params: { due: 'overdue' }
    assert_select 'article', /Overdue 3d/
    assert_select 'article', count: 1
    get_page projects_tasks_path, params: { mine: '1' }
    assert_select 'article', /Late thing/
    assert_select 'article', count: 1
  end

  test 'task transition finishes a task' do
    post transition_projects_task_path(@task, event: 'finish'), params: PARAMS
    assert_redirected_to @project
    assert task_now.done?
  end

  test 'move changes status through the state machine and stamps completion' do
    post move_projects_task_path(@task, **PARAMS), params: { status: 'in_progress' }, as: :json
    assert_response :success
    assert_equal 'in_progress', task_now.status

    post move_projects_task_path(@task, **PARAMS), params: { status: 'done' }, as: :json
    assert_equal 'done', task_now.status
    assert_not_nil @task.completed_at

    post move_projects_task_path(@task, **PARAMS), params: { status: 'todo' }, as: :json
    assert_equal 'todo', task_now.status
    assert_nil @task.completed_at
  end

  test 'move rejects an unknown column' do
    post move_projects_task_path(@task, **PARAMS), params: { status: 'nonsense' }, as: :json
    assert_response :unprocessable_entity
    assert_equal 'todo', task_now.status
  end

  test 'tasks can be added without a project' do
    post projects_tasks_path, params: PARAMS.merge(task: { title: 'Call the vendor', priority: 'low' }, assign_self: 1)
    as_user
    task = Projects::Task.find_by(title: 'Call the vendor')
    assert_not_nil task
    assert_nil task.project_id
    assert_equal @user.id.to_s, task.assignee_id
  end

  test 'a task cannot point at another tenant project' do
    other = Tenant.create!(name: 'Other', subdomain: 'other')
    foreign = Projects::Project.create!(name: 'Foreign', tenant_id: other.id)
    patch projects_task_path(@task), params: PARAMS.merge(task: { project_id: foreign.id })
    assert_equal @project.id.to_s, task_now.project_id
  end

  test 'project page shows a board and progress' do
    get_page projects_project_path(@project)
    assert_response :success
    assert_select 'h1', /Cleanup/
    assert_select "section[data-status='todo'] article", /Fix duplicate SKUs/
    assert_select "[role='img'][aria-label*='0 done']"
  end

  test 'project health flags overdue work' do
    as_user
    assert_equal :idle, Projects::Project.find(@project.id).health
    @task.update!(due_on: Date.current - 1)
    assert_equal :at_risk, Projects::Project.find(@project.id).health
  end

  test 'projects index shows stats and filters by search' do
    get_page projects_projects_path, params: { q: 'clean' }
    assert_response :success
    assert_select 'a h3', /Cleanup/
    get_page projects_projects_path, params: { q: 'zzz' }
    assert_select 'a h3', count: 0
  end

  test 'writers can assign reassign and unassign tasks and project owners' do
    teammate = User.create!(email: 'teammate@example.com', password: 'password123', role: 'manager', tenant: @tenant)
    post projects_tasks_path, params: PARAMS.merge(task: { title: 'Delegated', assignee_id: teammate.id, project_id: @project.id })
    as_user
    task = Projects::Task.find_by!(title: 'Delegated')
    assert_equal teammate.id.to_s, task.assignee_id
    patch projects_task_path(task), params: PARAMS.merge(task: { assignee_id: @user.id })
    as_user
    assert_equal @user.id.to_s, task.reload.assignee_id
    patch projects_task_path(task), params: PARAMS.merge(task: { assignee_id: '' })
    as_user
    assert task.reload.assignee_id.blank?

    post projects_projects_path, params: PARAMS.merge(project: { name: 'Delegated project', owner_id: teammate.id })
    as_user
    project = Projects::Project.find_by!(name: 'Delegated project')
    assert_equal teammate.id.to_s, project.owner_id
    patch projects_project_path(project), params: PARAMS.merge(project: { owner_id: '' })
    as_user
    assert project.reload.owner_id.blank?
  end

  test 'assignment rejects foreign inactive and nonexistent accounts atomically' do
    other = Tenant.create!(name: 'Other', subdomain: 'foreign-assignments')
    foreign = User.create!(email: 'foreign@example.com', password: 'password123', tenant: other)
    inactive = User.create!(email: 'inactive@example.com', password: 'password123', tenant: @tenant, active: false)
    [foreign.id, inactive.id, '999999999'].each do |id|
      patch projects_task_path(@task), params: PARAMS.merge(task: { title: 'Must not change', assignee_id: id })
      assert_equal 'Fix duplicate SKUs', task_now.title
      assert_nil @task.assignee_id
      patch projects_project_path(@project), params: PARAMS.merge(project: { name: 'Must not change', owner_id: id })
      assert_response :unprocessable_entity
      as_user
      assert_equal 'Cleanup', @project.reload.name
      assert_nil @project.owner_id
    end
    get_page projects_tasks_path
    assert_select 'select[name="task[assignee_id]"] option[value="' + foreign.id.to_s + '"]', count: 0
    assert_select 'select[name="task[assignee_id]"] option[value="' + inactive.id.to_s + '"]', count: 0
  end

  test 'invalid top level project never silently creates an orphan task' do
    other = Tenant.create!(name: 'Other', subdomain: 'foreign-project')
    foreign = Projects::Project.create!(name: 'Foreign', tenant: other)
    [foreign.id, '999999999'].each do |id|
      assert_no_difference 'Projects::Task.unscoped.count' do
        post projects_tasks_path, params: PARAMS.merge(project_id: id, task: { title: 'Must not exist' })
        assert_response :not_found
      end
    end
  end

  test 'self assignment flag respects false and explicit unassigned selection' do
    post projects_tasks_path, params: PARAMS.merge(assign_self: '0', task: { title: 'Not mine' })
    as_user
    assert_nil Projects::Task.find_by!(title: 'Not mine').assignee_id
    post projects_tasks_path, params: PARAMS.merge(assign_self: '1', task: { title: 'Explicitly unassigned', assignee_id: '' })
    as_user
    assert Projects::Task.find_by!(title: 'Explicitly unassigned').assignee_id.blank?
  end

  test 'deactivated existing assignee can be retained and cleared' do
    as_user
    @task.update!(assignee_id: @user.id)
    @user.update!(active: false)
    assert @task.update(title: 'Historical assignment')
    assert @task.update(assignee_id: nil)
    assert_not @task.update(assignee_id: @user.id)
  end

  test 'project deletion removes tasks and redirects to projects index' do
    delete projects_project_path(@project), params: PARAMS
    assert_redirected_to projects_projects_path
    assert_not Projects::Project.unscoped.exists?(@project.id)
    assert_not Projects::Task.unscoped.exists?(@task.id)
  end

  test 'read only project users cannot mutate tasks or projects' do
    reader = User.create!(email: 'project-reader@example.com', password: 'password123', role: 'reader', tenant: @tenant)
    reader.update_permission_overrides!(%w[projects.read])
    post login_path, params: { email: reader.email, password: 'password123' }
    get_page projects_tasks_path
    assert_response :success
    assert_select 'select[name="task[assignee_id]"]', count: 0
    assert_select '[draggable=true]', count: 0
    patch projects_task_path(@task), params: PARAMS.merge(task: { title: 'Forbidden' })
    post move_projects_task_path(@task, **PARAMS), params: { status: 'done' }, as: :json
    post transition_projects_task_path(@task), params: PARAMS.merge(event: 'finish')
    delete projects_task_path(@task), params: PARAMS
    post projects_tasks_path, params: PARAMS.merge(task: { title: 'Forbidden' })
    patch projects_project_path(@project), params: PARAMS.merge(project: { name: 'Forbidden' })
    post transition_projects_project_path(@project), params: PARAMS.merge(event: 'start')
    delete projects_project_path(@project), params: PARAMS
    post projects_projects_path, params: PARAMS.merge(project: { name: 'Forbidden' })
    assert_equal 'Fix duplicate SKUs', task_now.title
    assert_equal 'todo', @task.status
    assert_equal 'Cleanup', @project.reload.name
    assert_equal 'planned', @project.status
    assert_not Projects::Task.unscoped.exists?(title: 'Forbidden')
    assert_not Projects::Project.unscoped.exists?(name: 'Forbidden')
  end

  test 'other tenant records are inaccessible to every project and task endpoint' do
    other = Tenant.create!(name: 'Other', subdomain: 'isolated')
    foreign = Projects::Project.create!(name: 'Secret project', tenant: other)
    task = Projects::Task.create!(title: 'Secret task', project: foreign, tenant: other)
    get_page projects_tasks_path
    assert_select 'article', text: /Secret task/, count: 0
    get_page projects_project_path(foreign)
    assert_response :not_found
    patch projects_project_path(foreign), params: PARAMS.merge(project: { name: 'Forbidden' })
    assert_response :not_found
    delete projects_project_path(foreign), params: PARAMS
    assert_response :not_found
    post transition_projects_project_path(foreign), params: PARAMS.merge(event: 'start')
    assert_response :not_found
    patch projects_task_path(task), params: PARAMS.merge(task: { title: 'Forbidden' })
    assert_response :not_found
    delete projects_task_path(task), params: PARAMS
    assert_response :not_found
    post transition_projects_task_path(task), params: PARAMS.merge(event: 'finish')
    assert_response :not_found
    post move_projects_task_path(task), params: PARAMS.merge(status: 'done'), as: :json
    assert_response :not_found
  end

  test 'board limits are disclosed with access to the complete filtered list' do
    as_user
    limit = Projects::TasksController::BOARD_LIMIT
    Projects::Task.insert_all!(Array.new(limit) { |i| { title: "Task #{i}", project_id: @project.id, tenant_id: @tenant.id } })
    get_page projects_tasks_path, params: { project_id: @project.id }
    assert_select '[role="status"]', /Showing #{limit} of #{limit + 1} matching tasks/
    assert_select 'article', count: limit
    assert_select 'a[href=?]', projects_tasks_path(project_id: @project.id, view: 'list'), text: 'View all in the list'
    get_page projects_project_path(@project)
    assert_select '[role="status"]', /Showing #{limit} of #{limit + 1} tasks/
    assert_select 'article', count: limit
  end

  test 'assignment and workflow changes leave a tenant scoped actor audit trail' do
    patch projects_task_path(@task), params: PARAMS.merge(task: { assignee_id: @user.id })
    post move_projects_task_path(@task), params: PARAMS.merge(status: 'done'), as: :json
    as_user
    updates = ActivityLog.for_subject('Projects::Task', @task.id).where(action: %w[task_updated task_moved])
    assert_equal 2, updates.count
    assert_equal [@user.id], updates.distinct.pluck(:user_id)
    assert_equal [@tenant.id.to_s], updates.distinct.pluck(:tenant_id)
  end

  test 'stale task instances reload persisted state before a move' do
    as_user
    stale = Projects::Task.find(@task.id)
    @task.move_to!('done')
    assert stale.move_to!('todo')
    assert_equal 'todo', task_now.status
    assert_nil @task.completed_at
  end

  test 'legacy foreign assignee names are never displayed' do
    other = Tenant.create!(name: 'Other', subdomain: 'legacy-foreign')
    foreign = User.create!(email: 'secret-person@example.com', name: 'Secret Person', password: 'password123', tenant: other)
    @task.update_columns(assignee_id: foreign.id)
    get_page projects_tasks_path
    assert_not_includes response.body, 'Secret Person'
    get_page projects_project_path(@project)
    assert_not_includes response.body, 'Secret Person'
  end

  test 'invalid legacy assignments produce a validation response when moved' do
    @task.update_columns(assignee_id: '999999999')
    post move_projects_task_path(@task), params: PARAMS.merge(status: 'done'), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'workspace'
    assert_equal 'todo', task_now.status
    assert_nil @task.completed_at
  end
end
