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
    assert_select 'h3', /Cleanup/
    get_page projects_projects_path, params: { q: 'zzz' }
    assert_select 'h3', count: 0
  end
end
