# frozen_string_literal: true

require 'test_helper'

# Task detail (comments, checklist, dependencies, time, files), notifications,
# project workflow (reopen, completion choice, goals, members, templates),
# timeline and calendar views, CSV export and hand-placed board order.
class ProjectManagementTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = User.create!(tenant: @tenant, email: 'pm-admin@example.com', role: 'admin', password: 'password123')
    @worker = User.create!(tenant: @tenant, email: 'pm-worker@example.com', role: 'employee', password: 'password123')
    @other_worker = User.create!(tenant: @tenant, email: 'pm-other@example.com', role: 'employee', password: 'password123')
    @project = Projects::Project.create!(name: 'Launch', owner_id: @admin.id.to_s)
    @task = Projects::Task.create!(project: @project, title: 'Write copy', assignee_id: @worker.id.to_s, due_on: Date.current + 3)
    sign_in(@admin)
  end

  teardown { Current.reset }

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def tenant!
    Current.tenant = @tenant
  end

  def fresh(record)
    tenant!
    record.class.find(record.id)
  end

  def notices_for(user)
    tenant!
    Notification.where(user_id: user.id).order(:id).to_a
  end

  def task!(title, **attrs)
    tenant!
    Projects::Task.create!({ project: @project, title: title }.merge(attrs))
  end

  # --- task detail ---------------------------------------------------------

  test 'task page shows every section for a manager' do
    get projects_task_path(@task)
    assert_response :success
    assert_select 'h1', text: /Write copy/
    %w[checklist waiting time files discussion history].each { |id| assert_select "section##{id}" }
    assert_select 'details summary', text: 'Edit task'
  end

  test 'other workspaces cannot open a task' do
    other = Tenant.create!(name: 'Elsewhere', subdomain: 'pm-elsewhere')
    foreign = Projects::Task.create!(tenant: other, title: 'Not yours')
    get projects_task_path(foreign)
    assert_response :not_found
  end

  test 'employees reach only their own task page and cannot see a roster or manager controls' do
    sign_in(@worker)
    get projects_task_path(@task)
    assert_response :success
    assert_select 'section#waiting form', count: 0
    assert_select 'form[action=?]', projects_task_path(@task) # edit form for title and notes
    assert_select 'select[name="task[assignee_id]"]', count: 0
    assert_select 'button', text: 'Delete task', count: 0
    sign_in(@other_worker)
    get projects_task_path(@task)
    assert_response :not_found
  end

  test 'comments are saved, notify the team but not the author, and need text' do
    @project.update!(project_members: [Projects::ProjectMember.new(user: @other_worker, tenant_id: @tenant.id)])
    sign_in(@worker)
    post projects_task_comments_path(@task), params: { comment: { body: 'Draft is ready' } }
    assert_redirected_to projects_task_path(@task, anchor: 'discussion')
    assert_equal ['Draft is ready'], fresh(@task).comments.map(&:body)
    assert_equal [@admin.id, @other_worker.id].sort, notices_for(@admin).concat(notices_for(@other_worker)).map(&:user_id).sort
    assert_empty notices_for(@worker)
    post projects_task_comments_path(@task), params: { comment: { body: '  ' } }
    assert_equal 1, fresh(@task).comments.count
    follow_redirect!
    assert_includes response.body, 'Draft is ready'
  end

  test 'an unassigned coworker cannot comment or change anything on the task' do
    sign_in(@other_worker)
    post projects_task_comments_path(@task), params: { comment: { body: 'Nope' } }
    assert_response :not_found
    assert_equal 0, fresh(@task).comments.count
  end

  test 'checklist items can be added, ticked, unticked and removed' do
    post projects_task_checklist_items_path(@task), params: { item: { title: 'Proofread' } }
    item = fresh(@task).checklist_items.first
    assert_equal [0, 1], fresh(@task).checklist_progress
    patch projects_task_checklist_item_path(@task, item, done: true)
    assert_equal [1, 1], fresh(@task).checklist_progress
    patch projects_task_checklist_item_path(@task, item)
    assert_equal [0, 1], fresh(@task).checklist_progress
    post projects_task_checklist_items_path(@task), params: { item: { title: '' } }
    assert_equal 1, fresh(@task).checklist_items.count
    delete projects_task_checklist_item_path(@task, item)
    assert_equal 0, fresh(@task).checklist_items.count
  end

  test 'read only users cannot add to a task' do
    reader = User.create!(tenant: @tenant, email: 'pm-reader@example.com', role: 'reader', password: 'password123')
    reader.update_permission_overrides!(%w[projects.read])
    sign_in(reader)
    get projects_task_path(@task)
    assert_response :success
    assert_select 'form[action=?]', projects_task_comments_path(@task), count: 0
    post projects_task_comments_path(@task), params: { comment: { body: 'No' } }
    post projects_task_time_entries_path(@task), params: { entry: { hours: '1' } }
    assert_equal 0, fresh(@task).comments.count
    assert_equal 0, fresh(@task).time_entries.count
  end

  # --- blocked reason ------------------------------------------------------

  test 'blocking records a reason, tells the team and clears when work resumes' do
    sign_in(@worker)
    post transition_projects_task_path(@task, event: 'block'), params: { reason: 'Need the product photos' }
    task = fresh(@task)
    assert task.blocked?
    assert_equal 'Need the product photos', task.blocked_reason
    note = notices_for(@admin).last
    assert_equal 'task_blocked', note.kind
    assert_equal 'Need the product photos', note.body
    get projects_task_path(@task)
    assert_includes response.body, 'Need the product photos'
    post transition_projects_task_path(@task, event: 'reopen')
    assert_nil fresh(@task).blocked_reason
    assert fresh(@task).todo?
  end

  test 'a dragged blocked card shows its reason on the board' do
    tenant!
    @task.block_with_reason!('Waiting on legal')
    get projects_tasks_path
    assert_select 'article[data-task-id]', text: /Blocked: Waiting on legal/
  end

  # --- dependencies --------------------------------------------------------

  test 'a task waits on its blockers and is released when they finish' do
    blocker = task!('Approve budget', assignee_id: @admin.id.to_s)
    post projects_task_dependencies_path(@task), params: { dependency: { blocker_id: blocker.id } }
    assert_equal [blocker.id], fresh(@task).blockers.pluck(:id)

    post transition_projects_task_path(@task, event: 'start')
    assert_match(/Waiting on Approve budget/, flash[:alert])
    assert fresh(@task).todo?
    post move_projects_task_path(@task), params: { status: 'done' }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Waiting on Approve budget/, response.parsed_body['error'])

    sign_in(@admin)
    post transition_projects_task_path(blocker, event: 'finish')
    assert fresh(blocker).done?
    ready = notices_for(@worker).find { |n| n.kind == 'task_unblocked' }
    assert_equal 'Ready to start: Write copy', ready.title

    sign_in(@worker)
    post transition_projects_task_path(@task, event: 'start')
    assert fresh(@task).in_progress?
  end

  test 'circular and self dependencies are refused' do
    other = task!('Second')
    post projects_task_dependencies_path(@task), params: { dependency: { blocker_id: other.id } }
    post projects_task_dependencies_path(other), params: { dependency: { blocker_id: @task.id } }
    assert_match(/wait on each other/, flash[:alert])
    post projects_task_dependencies_path(@task), params: { dependency: { blocker_id: @task.id } }
    assert_equal 1, Projects::TaskDependency.unscoped.where(tenant_id: @tenant.id).count
  end

  test 'only planners can add or remove dependencies and foreign tasks cannot be picked' do
    other_tenant = Tenant.create!(name: 'Elsewhere', subdomain: 'pm-dep-else')
    foreign = Projects::Task.create!(tenant: other_tenant, title: 'Foreign')
    post projects_task_dependencies_path(@task), params: { dependency: { blocker_id: foreign.id } }
    assert_equal 0, fresh(@task).dependencies.count
    sign_in(@worker)
    blocker = task!('Mine too', assignee_id: @worker.id.to_s)
    post projects_task_dependencies_path(@task), params: { dependency: { blocker_id: blocker.id } }
    assert_equal 0, fresh(@task).dependencies.count
  end

  # --- time ---------------------------------------------------------------

  test 'time parses common formats and totals on the task and project' do
    { '1.5' => 90, '1:30' => 90, '90m' => 90, '2h' => 120, '45 min' => 45 }.each do |text, minutes|
      assert_equal minutes, Projects::TaskTimeEntry.parse_minutes(text), text
    end
    assert_nil Projects::TaskTimeEntry.parse_minutes('soon')

    @task.update!(estimate_hours: '4')
    post projects_task_time_entries_path(@task), params: { entry: { hours: '1:30', note: 'Outline' } }
    post projects_task_time_entries_path(@task), params: { entry: { hours: 'lots' } }
    assert_match(/Enter the time/, flash[:alert])
    task = fresh(@task)
    assert_equal 90, task.logged_minutes
    assert_equal 240, task.estimate_minutes
    assert_equal 90, fresh(@project).logged_minutes
    get projects_project_path(@project)
    assert_includes response.body, '1h 30m'
  end

  test 'people remove only their own time unless they manage projects' do
    tenant!
    mine = @task.time_entries.create!(minutes: 30, logged_on: Date.current, user: @worker)
    theirs = @task.time_entries.create!(minutes: 45, logged_on: Date.current, user: @admin)
    sign_in(@worker)
    delete projects_task_time_entry_path(@task, theirs)
    assert_equal 2, fresh(@task).time_entries.count
    delete projects_task_time_entry_path(@task, mine)
    assert_equal [theirs.id], fresh(@task).time_entries.pluck(:id)
  end

  # --- files --------------------------------------------------------------

  test 'files attach, download only as attachments and reject lookalikes' do
    png = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\nrest".b), 'image/png', original_filename: 'mock.png')
    post projects_task_attachments_path(@task), params: { file: png }
    file = fresh(@task).attachments.first
    assert_equal 'image/png', file.content_type
    get projects_task_attachment_path(@task, file)
    assert_response :success
    assert_match(/attachment/, response.headers['Content-Disposition'])
    assert_equal 'image/png', response.media_type

    script = Rack::Test::UploadedFile.new(StringIO.new('<script>alert(1)</script>'), 'text/html', original_filename: 'x.html')
    post projects_task_attachments_path(@task), params: { file: script }
    assert_match(/Only PNG/, flash[:alert])
    fake = Rack::Test::UploadedFile.new(StringIO.new('not a pdf'), 'application/pdf', original_filename: 'fake.pdf')
    post projects_task_attachments_path(@task), params: { file: fake }
    assert_match(/does not look like/, flash[:alert])
    assert_equal 1, fresh(@task).attachments.count

    delete projects_task_attachment_path(@task, file)
    assert_equal 0, fresh(@task).attachments.count
  end

  test 'oversize files are refused and an unassigned employee cannot download' do
    big = Rack::Test::UploadedFile.new(StringIO.new('a' * (Projects::TaskAttachment::MAX_BYTES + 10)), 'text/plain', original_filename: 'big.txt')
    post projects_task_attachments_path(@task), params: { file: big }
    assert_match(/5 MB/, flash[:alert])
    tenant!
    @task.attachments.create!(filename: 'a.txt', content_type: 'text/plain', byte_size: 1, body: 'a')
    sign_in(@other_worker)
    get projects_task_attachment_path(@task, fresh(@task).attachments.first)
    assert_response :not_found
  end

  # --- notifications ------------------------------------------------------

  test 'assigning a task notifies the assignee but never the person assigning to themselves' do
    post projects_tasks_path, params: { project_id: @project.id, task: { title: 'Pack boxes', assignee_id: @worker.id } }
    note = notices_for(@worker).last
    assert_equal 'task_assigned', note.kind
    assert_match(/Pack boxes/, note.title)
    post projects_tasks_path, params: { project_id: @project.id, task: { title: 'Mine', assignee_id: @admin.id } }
    assert_empty notices_for(@admin).select { |n| n.title.include?('Mine') }
    patch projects_task_path(@task), params: { task: { assignee_id: @other_worker.id } }
    assert_equal 'task_assigned', notices_for(@other_worker).last.kind
  end

  test 'the bell shows unread counts and opening a notification marks it read and goes to the task' do
    post projects_task_comments_path(@task), params: { comment: { body: 'Hello' } }
    sign_in(@worker)
    get projects_tasks_path
    assert_select 'a[href=?][aria-label=?]', notifications_path, 'Notifications, 1 unread'
    get notifications_path
    assert_response :success
    assert_select 'li', text: /commented on: Write copy/
    note = notices_for(@worker).last
    get notification_path(note)
    assert_redirected_to projects_task_path(@task)
    assert fresh(note).read?
    get projects_tasks_path
    assert_select 'a[aria-label=?]', 'Notifications'
  end

  test 'notifications are private, mark-all works and stored urls cannot redirect off site' do
    tenant!
    mine = Notification.create!(user: @worker, kind: 'x', title: 'Mine', url: '//evil.example/path')
    theirs = Notification.create!(user: @other_worker, kind: 'x', title: 'Theirs', url: '/dashboard')
    sign_in(@worker)
    get notifications_path
    assert_includes response.body, 'Mine'
    assert_not_includes response.body, 'Theirs'
    get notification_path(theirs)
    assert_response :not_found
    get notification_path(mine)
    assert_redirected_to notifications_path
    post read_all_notifications_path
    assert_equal 0, Notification.unread_count_for(@worker)
    assert_equal 1, Notification.unread_count_for(@other_worker)
  end

  test 'daily reminders cover due and overdue tasks once each' do
    due = task!('Due today', assignee_id: @worker.id.to_s, due_on: Date.current)
    late = task!('Late', assignee_id: @worker.id.to_s, due_on: Date.current - 3)
    task!('Later', assignee_id: @worker.id.to_s, due_on: Date.current + 9)
    task!('Done late', assignee_id: @worker.id.to_s, due_on: Date.current - 3).tap { |t| t.finish! }
    2.times { TaskReminderJob.perform_now }
    titles = notices_for(@worker).map(&:title)
    assert_equal 1, titles.count { |t| t.include?('Due today') }
    assert_equal 1, titles.count { |t| t.include?('Overdue 3d: Late') }
    assert_equal 0, titles.count { |t| t.include?('Later') || t.include?('Done late') }
    assert_equal [due.id, late.id].sort, Projects::Task.where(title: ['Due today', 'Late']).ids.sort
  end

  test 'the dashboard offers a My tasks widget listing assigned open work' do
    tenant!
    @task.update!(assignee_id: @admin.id.to_s)
    get root_path
    assert_response :success
    assert_select 'h2', text: 'My tasks'
    assert_includes response.body, 'Write copy'
  end

  # --- recurrence ---------------------------------------------------------

  test 'finishing a repeating task creates the next one once' do
    tenant!
    @task.update!(recurrence: 'weekly', due_on: Date.current, estimate_hours: '2', labels_text: 'Weekly, Ops')
    @task.checklist_items.create!(title: 'Count till', done: true)
    post transition_projects_task_path(@task, event: 'finish')
    tenant!
    copies = Projects::Task.where(title: 'Write copy').where.not(id: @task.id)
    assert_equal 1, copies.count
    copy = copies.first
    assert_equal Date.current + 7, copy.due_on
    assert_equal 'todo', copy.status
    assert_equal %w[Weekly Ops], copy.labels
    assert_equal 120, copy.estimate_minutes
    assert_equal [['Count till', false]], copy.checklist_items.map { |i| [i.title, i.done] }
    assert_equal @worker.id.to_s, copy.assignee_id
    post transition_projects_task_path(@task, event: 'reopen')
    post transition_projects_task_path(@task, event: 'finish')
    tenant!
    assert_equal 1, Projects::Task.where(title: 'Write copy').where.not(id: @task.id).count
  end

  test 'a late repeating task skips to the next date that is still ahead' do
    tenant!
    @task.update!(recurrence: 'daily', due_on: Date.current - 5)
    @task.finish!
    copy = Projects::Task.where(title: 'Write copy').where.not(id: @task.id).first
    assert_equal Date.current, copy.due_on
  end

  # --- labels, estimate ---------------------------------------------------

  test 'labels are trimmed, de-duplicated, limited and filterable' do
    tenant!
    @task.update!(labels_text: ' Rush , rush,  Print ,')
    assert_equal %w[Rush Print], @task.reload.labels
    assert_not @task.update(labels_text: (1..11).map { |i| "l#{i}" }.join(','))
    task!('Other', labels_text: 'Web')
    get projects_tasks_path, params: { label: 'rush' }
    assert_select 'article[data-task-id]', count: 1
    assert_includes response.body, 'Write copy'
  end

  # --- project workflow ---------------------------------------------------

  test 'completed and archived projects can be reopened' do
    @project.update_columns(status: 'completed')
    post transition_projects_project_path(@project, event: 'reopen')
    assert fresh(@project).active?
    @project.update_columns(status: 'archived')
    post transition_projects_project_path(@project, event: 'reopen')
    assert fresh(@project).active?
    assert_match(/reopened/, flash[:notice])
    post transition_projects_project_path(@project, event: 'reopen')
    assert_match(/Cannot reopen/, flash[:alert])
  end

  test 'completing with open tasks needs a choice, and either choice is honoured' do
    @project.update_columns(status: 'active')
    done = task!('Finished already')
    done.finish!
    post transition_projects_project_path(@project, event: 'complete')
    assert_match(/1 task still open/, flash[:alert])
    assert fresh(@project).active?

    post transition_projects_project_path(@project, event: 'complete', open_tasks: 'leave')
    assert fresh(@project).completed?
    assert fresh(@task).todo?

    @project.update_columns(status: 'active')
    post transition_projects_project_path(@project, event: 'complete', open_tasks: 'finish')
    assert fresh(@project).completed?
    assert fresh(@task).done?
    assert_not_nil fresh(@task).completed_at
  end

  test 'finishing open tasks respects dependencies and reports what stayed open' do
    @project.update_columns(status: 'active')
    blocker = task!('Approve')
    @task.dependencies.create!(blocker: blocker)
    post transition_projects_project_path(@project, event: 'complete', open_tasks: 'finish')
    assert fresh(@project).completed?
    assert fresh(@task).done?
    assert fresh(blocker).done?
  end

  test 'completing a project with no open work needs no choice' do
    @project.update_columns(status: 'active')
    @task.finish!
    post transition_projects_project_path(@project, event: 'complete')
    assert fresh(@project).completed?
    assert_equal 'Project completed.', flash[:notice]
  end

  test 'unknown project events are refused' do
    post transition_projects_project_path(@project, event: 'explode')
    assert_match(/Cannot explode/, flash[:alert])
    assert_equal 'planned', fresh(@project).status
  end

  test 'the edit page warns what deleting removes' do
    get edit_projects_project_path(@project)
    assert_select 'form[action=?] input[value=delete]', projects_project_path(@project)
    assert_includes response.body, '1 task'
  end

  # --- goals --------------------------------------------------------------

  test 'a project can support a goal of its own workspace and the goal lists it' do
    tenant!
    goal = Goals::Goal.create!(name: 'Grow wholesale', target_value: 10, current_value: 4)
    patch projects_project_path(@project), params: { project: { goal_id: goal.id } }
    assert_equal goal.id, fresh(@project).goal_id
    get projects_project_path(@project)
    assert_select 'a[href=?]', goals_goal_path(goal), text: 'Grow wholesale'
    get goals_goal_path(goal)
    assert_select 'a[href=?]', projects_project_path(@project), text: 'Launch'

    other = Tenant.create!(name: 'Elsewhere', subdomain: 'pm-goal-else')
    foreign = Goals::Goal.unscoped.create!(tenant_id: other.id, name: 'Foreign goal')
    patch projects_project_path(@project), params: { project: { goal_id: foreign.id } }
    assert_equal goal.id, fresh(@project).goal_id
  end

  # --- members ------------------------------------------------------------

  test 'members are saved for active workspace people only' do
    other = Tenant.create!(name: 'Elsewhere', subdomain: 'pm-member-else')
    stranger = User.create!(tenant: other, email: 'pm-stranger@example.com', role: 'admin', password: 'password123')
    gone = User.create!(tenant: @tenant, email: 'pm-gone@example.com', role: 'employee', password: 'password123', active: false)
    patch projects_project_path(@project), params: { project: { member_ids: ['', @worker.id, stranger.id, gone.id, 'x'] } }
    assert_equal [@worker.id], fresh(@project).members.pluck(:id)
    get projects_project_path(@project)
    assert_includes response.body, 'Team:'
    patch projects_project_path(@project), params: { project: { member_ids: [''] } }
    assert_empty fresh(@project).members
  end

  # --- templates ----------------------------------------------------------

  test 'a project can be saved as a template and reused with dates shifted' do
    tenant!
    @project.update!(start_on: Date.new(2026, 11, 1), due_on: Date.new(2026, 11, 30))
    @task.update!(start_on: Date.new(2026, 11, 3), due_on: Date.new(2026, 11, 10), labels_text: 'Copy')
    @task.checklist_items.create!(title: 'Outline', done: true)
    post save_template_projects_project_path(@project), params: { name: 'Launch kit' }
    template = Projects::ProjectTemplate.find_by(name: 'Launch kit')
    assert_equal 1, template.task_count

    get new_projects_project_path
    assert_select 'select[name=template_id] option', text: /Launch kit \(1 task\)/

    post projects_projects_path, params: { template_id: template.id, project: { name: 'Winter launch', start_on: '2027-01-04' } }
    tenant!
    made = Projects::Project.find_by!(name: 'Winter launch')
    task = made.tasks.first
    assert_equal 'Write copy', task.title
    assert_equal Date.new(2027, 1, 6), task.start_on
    assert_equal Date.new(2027, 1, 13), task.due_on
    assert_equal ['Copy'], task.labels
    assert_equal [['Outline', false]], task.checklist_items.map { |i| [i.title, i.done] }
    assert_nil task.assignee_id
    assert_equal Date.new(2027, 2, 2), made.due_on # 29 days after the new start, as in the template
    assert_not Projects::Project.exists?(name: 'Launch kit'), 'templates never appear as projects'
  end

  test 'templates can be deleted and stay out of every board' do
    tenant!
    template = Projects::ProjectTemplate.capture(@project, name: 'Temp')
    get projects_tasks_path
    assert_select 'article[data-task-id]', count: 1
    delete projects_template_path(template)
    assert_nil Projects::ProjectTemplate.find_by(id: template.id)
  end

  test 'read only users cannot save or delete templates' do
    reader = User.create!(tenant: @tenant, email: 'pm-reader2@example.com', role: 'reader', password: 'password123')
    reader.update_permission_overrides!(%w[projects.read])
    tenant!
    template = Projects::ProjectTemplate.capture(@project, name: 'Keep')
    sign_in(reader)
    post save_template_projects_project_path(@project), params: { name: 'Nope' }
    delete projects_template_path(template)
    assert_equal ['Keep'], Projects::ProjectTemplate.all.map(&:name)
  end

  # --- timeline and calendar ---------------------------------------------

  test 'the timeline draws a bar for each dated task and lists the rest' do
    tenant!
    @task.update!(start_on: Date.current, due_on: Date.current + 9)
    task!('Undated')
    get projects_project_path(@project, view: 'timeline')
    assert_response :success
    assert_select 'section[aria-label="Project timeline"] ol li a', text: 'Write copy'
    assert_select 'section[aria-label="Project timeline"]', text: /No dates yet/
    assert_select 'section[aria-label="Project timeline"] a', text: 'Undated'
  end

  test 'the calendar shows tasks on their due date and tolerates a bad month' do
    tenant!
    @task.update!(due_on: Date.new(2026, 11, 12))
    get projects_tasks_path, params: { view: 'calendar', month: '2026-11' }
    assert_response :success
    assert_select 'h2', text: 'November 2026'
    assert_select 'section[aria-label="Task calendar"] a', text: 'Write copy'
    get projects_tasks_path, params: { view: 'calendar', month: 'garbage' }
    assert_response :success
    assert_select 'h2', text: Date.current.strftime('%B %Y')
  end

  # --- export -------------------------------------------------------------

  test 'tasks export as CSV with filters and spreadsheet formulas neutralised' do
    tenant!
    @task.update!(title: '=HYPERLINK("http://x")', labels_text: 'a,b')
    task!('Other', priority: 'urgent')
    get export_projects_tasks_path, params: { q: 'HYPER' }
    assert_response :success
    assert_equal 'text/csv', response.media_type
    rows = CSV.parse(response.body)
    assert_equal 2, rows.size
    assert_equal "'=HYPERLINK(\"http://x\")", rows[1][1]
    assert_equal 'a; b', rows[1][8]
    assert_equal 'Launch', rows[1][2]
  end

  test 'projects export as CSV and need project access' do
    get export_projects_projects_path
    assert_response :success
    assert_equal 'Launch', CSV.parse(response.body)[1][0]
    cashier = User.create!(tenant: @tenant, email: 'pm-cashier@example.com', role: 'cashier', password: 'password123')
    sign_in(cashier)
    get export_projects_projects_path
    assert_redirected_to root_path
  end

  # --- hand-placed order --------------------------------------------------

  test 'dropping cards in a column saves their order and the board honours it' do
    first = task!('First', priority: 'low')
    second = task!('Second', priority: 'urgent')
    post move_projects_task_path(first), params: { status: 'todo', ordered_ids: [first.id, second.id, @task.id] }, as: :json
    assert_response :success
    assert_equal [0, 1, 2], [first, second, @task].map { |t| fresh(t).position }
    get projects_project_path(@project)
    titles = css_select('article[data-status=todo] p a').map(&:text)
    assert_equal ['First', 'Second', 'Write copy'], titles
  end

  test 'ordering never touches tasks the person cannot change' do
    sign_in(@worker)
    mine = @task
    theirs = task!('Not mine', assignee_id: @other_worker.id.to_s)
    post move_projects_task_path(mine), params: { status: 'todo', ordered_ids: [theirs.id, mine.id] }, as: :json
    assert_nil fresh(theirs).position
    assert_equal 1, fresh(mine).position
  end

  test 'stale reorders from a board with cards in other columns are harmless' do
    done = task!('Closed')
    done.finish!
    post move_projects_task_path(@task), params: { status: 'in_progress', ordered_ids: [@task.id, 'junk', 0, done.id] }, as: :json
    assert_response :success
    assert fresh(@task).in_progress?
  end
end
