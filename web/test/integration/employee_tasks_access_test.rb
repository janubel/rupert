# frozen_string_literal: true

require 'test_helper'

class EmployeeTasksAccessTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @employee = User.create!(tenant: @tenant, email: 'assigned-staff@example.com', role: 'employee', password: 'password123')
    @coworker = User.create!(tenant: @tenant, email: 'other-staff@example.com', role: 'employee', password: 'password123')
    @project = Projects::Project.create!(name: 'Assigned project', description: 'Private project planning')
    @hidden_project = Projects::Project.create!(name: 'Hidden project')
    @mine = Projects::Task.create!(title: 'My assigned work', description: 'My notes', project: @project,
      assignee: @employee, priority: 'high', due_on: Date.yesterday)
    @others = Projects::Task.create!(title: 'Coworker secret', description: 'Other private notes', project: @project,
      assignee: @coworker, priority: 'urgent', due_on: Date.yesterday)
    @unassigned = Projects::Task.create!(title: 'Unassigned secret', project: @hidden_project)
    other_tenant = Tenant.create!(name: 'Foreign workspace', subdomain: 'foreign-staff-tasks')
    @foreign = Projects::Task.create!(tenant: other_tenant, title: 'Foreign secret')
    # Even an invalid legacy cross-workspace assignment must not confer access.
    @foreign.update_columns(assignee_id: @employee.id)
    post login_path, params: { email: @employee.email, password: 'password123' }
  end

  teardown { Current.reset }

  test 'board list filters counts and navigation expose only assigned workspace tasks' do
    [{}, { view: 'list' }, { mine: '0' }, { mine: '1' }, { due: 'overdue' }].each do |filters|
      get projects_tasks_path, params: filters
      assert_response :success
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_select 'h1', 'My tasks'
      assert_includes response.body, @mine.title
      assert_select '.stat .stat-value', text: '1', count: 2 # Open and overdue, excluding coworkers.
      assert_select '.stat .stat-value', text: '0', count: 2
      assert_select 'a[href=?]', projects_tasks_path, text: 'My tasks'
      assert_select 'a[href=?]', projects_project_path(@project), count: 0
      assert_select 'a[href=?]', projects_projects_path, count: 0
      assert_select 'select[name="project_id"] option[value=?]', @project.id.to_s, text: @project.name
      assert_select 'select[name="project_id"] option[value=?]', @hidden_project.id.to_s, count: 0
      assert_select 'select[name="task[assignee_id]"]', count: 0
      assert_select 'input[name="task[due_on]"]', count: 0
      assert_select 'select[name="task[priority]"]', count: 0
      assert_select 'form[action=?][method="post"] input[value="delete"]', projects_task_path(@mine), count: 0
      assert_no_private_work
    end
    get projects_tasks_path, params: { q: 'secret', mine: '0', project_id: @hidden_project.id }
    assert_response :success
    assert_select 'article[data-task-id]', count: 0
    assert_no_private_work
  end

  test 'pagination cannot broaden assignment visibility' do
    Current.tenant = @tenant
    Projects::Task.insert_all!(Array.new(32) { |i| { tenant_id: @tenant.id, assignee_id: @employee.id, title: "My extra #{i}" } })
    get projects_tasks_path, params: { view: 'list', page: 2, mine: '0' }
    assert_response :success
    assert_includes response.body, 'My extra'
    assert_no_private_work
  end

  test 'employee can edit own title and notes without changing assignment planning or workspace' do
    before = @mine.attributes
    patch projects_task_path(@mine), params: { task: { title: 'Updated work', description: 'Progress notes',
      assignee_id: @coworker.id, project_id: @hidden_project.id, tenant_id: @foreign.tenant_id,
      priority: 'urgent', due_on: Date.tomorrow, status: 'done', completed_at: Time.current } }
    assert_redirected_to projects_tasks_path
    saved = task_now(@mine)
    assert_equal 'Updated work', saved.title
    assert_equal 'Progress notes', saved.description
    %w[assignee_id project_id tenant_id priority due_on status completed_at].each do |field|
      if before[field].nil?
        assert_nil saved.attributes[field], field
      else
        assert_equal before[field], saved.attributes[field], field
      end
    end
    log = ActivityLog.unscoped.find_by!(subject_type: 'Projects::Task', subject_id: @mine.id, action: 'task_updated')
    assert_equal @employee.id, log.user_id
    assert_equal @tenant.id.to_s, log.tenant_id
  end

  test 'assigned employee can start block reopen finish and move tasks' do
    %w[start block reopen finish].each do |event|
      post transition_projects_task_path(@mine), params: { event: event }
      assert_redirected_to projects_tasks_path
    end
    assert task_now(@mine).done?
    assert_not_nil @mine.completed_at
    post move_projects_task_path(@mine), params: { status: 'todo' }, as: :json
    assert_response :success
    assert_equal 'todo', response.parsed_body['status']
    assert_nil task_now(@mine).completed_at
    post move_projects_task_path(@mine), params: { status: 'done' }, as: :json
    assert_response :success
    assert task_now(@mine).done?
    assert_not_nil @mine.completed_at
  end

  test 'unassigned coworker foreign and missing tasks are inaccessible to mutation endpoints' do
    [@others.id, @unassigned.id, @foreign.id, 'missing-task'].each do |id|
      patch projects_task_path(id), params: { task: { title: 'Forbidden' } }, as: :json
      assert_response :not_found
      post transition_projects_task_path(id), params: { event: 'finish' }, as: :json
      assert_response :not_found
      post move_projects_task_path(id), params: { status: 'done' }, as: :json
      assert_response :not_found
    end
    [@others, @unassigned, @foreign].each do |task|
      refute_equal 'Forbidden', task_now(task).title
      assert_equal 'todo', task.status
      assert_nil task.completed_at
    end
  end

  test 'employees cannot create delete or read and manage entire projects' do
    assert_no_difference ['Projects::Task.unscoped.count', 'Projects::Project.unscoped.count'] do
      post projects_tasks_path, params: { task: { title: 'Forbidden', assignee_id: @employee.id } }, as: :json
      assert_response :forbidden
      delete projects_task_path(@mine), as: :json
      assert_response :forbidden
      get projects_projects_path, as: :json
      assert_response :forbidden
      get projects_project_path(@project), as: :json
      assert_response :forbidden
      patch projects_project_path(@project), params: { project: { name: 'Forbidden' } }, as: :json
      assert_response :forbidden
      post transition_projects_project_path(@project), params: { event: 'start' }, as: :json
      assert_response :forbidden
      delete projects_project_path(@project), as: :json
      assert_response :forbidden
      post projects_projects_path, params: { project: { name: 'Forbidden' } }, as: :json
      assert_response :forbidden
    end
    assert_equal 'Assigned project', Projects::Project.unscoped.find(@project.id).name
  end

  test 'stale wide permission overrides cannot expand assigned-task access' do
    %w[* projects.read projects.write].each do |permission|
      @employee.user_permissions.create!(tenant_id: @tenant.id, permission: permission, enabled: true)
      RolePermission.create!(tenant_id: @tenant.id, role: 'employee', permission: permission, enabled: true)
    end
    get projects_tasks_path
    assert_response :success
    assert_no_private_work
    post move_projects_task_path(@others), params: { status: 'done' }, as: :json
    assert_response :not_found
    get projects_project_path(@project), as: :json
    assert_response :forbidden
    get reports_path, as: :json
    assert_response :forbidden
  end

  test 'reassignment immediately removes former assignee access' do
    @mine.update_columns(assignee_id: @coworker.id)
    get projects_tasks_path
    assert_response :success
    assert_select 'article[data-task-id]', count: 0
    patch projects_task_path(@mine), params: { task: { description: 'Former assignee' } }, as: :json
    assert_response :not_found
    post move_projects_task_path(@mine), params: { status: 'done' }, as: :json
    assert_response :not_found
    assert_equal 'My notes', task_now(@mine).description
    assert_equal 'todo', @mine.status
  end

  test 'reassignment between lookup and locked write denies an in-flight employee request' do
    [[:patch, projects_task_path(@mine), { task: { title: 'Too late' } }],
     [:post, transition_projects_task_path(@mine), { event: 'finish' }],
     [:post, move_projects_task_path(@mine), { status: 'done' }]].each do |method, path, attributes|
      @mine.update_columns(assignee_id: @employee.id)
      reassigned = false
      subscriber = lambda do |*, payload|
        next if reassigned || !payload[:sql].start_with?('SELECT') || !payload[:sql].include?('"tasks"')

        # The lookup has returned its old row, but the write's row lock has not
        # yet reloaded it. Simulate a manager's intervening reassignment.
        reassigned = true
        Projects::Task.unscoped.where(id: @mine.id).update_all(assignee_id: @coworker.id)
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        public_send(method, path, params: attributes, as: :json)
      end
      assert reassigned
      assert_response :redirect
      assert_equal 'My assigned work', task_now(@mine).title
      assert_equal 'todo', @mine.status
      assert_equal @coworker.id.to_s, @mine.assignee_id
    end
  end

  test 'inactive employees cannot read or change assigned work' do
    @employee.update!(active: false)
    get projects_tasks_path
    assert_redirected_to login_path
    post move_projects_task_path(@mine), params: { status: 'done' }, as: :json
    assert_redirected_to login_path
    assert_equal 'todo', task_now(@mine).status
  end

  private

  def task_now(task)
    Projects::Task.unscoped { task.reload }
  end

  def assert_no_private_work
    [@others.title, @unassigned.title, @foreign.title, @hidden_project.name, 'Other private notes', 'Private project planning'].each do |secret|
      assert_not_includes response.body, secret
    end
  end
end
