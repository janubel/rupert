# frozen_string_literal: true

require 'test_helper'

class TaskAiActivityTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @requester = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @requester
    @approver = User.create!(tenant: @tenant, name: 'Approving person', email: 'activity-approver@example.com', role: @requester.role, password: 'password123')
    @room = TeamChat::Room.create!(name: 'AI source', slug: 'activity-source', kind: 'channel', created_by: @requester, assistant_mode: 'off')
  end
  teardown { Current.reset }

  def approve(tool, args, body, parent: nil)
    Current.tenant = @tenant
    Current.user = @requester
    trigger = @room.messages.create!(author_kind: 'person', user: @requester, body: body, parent: parent)
    reply = @room.messages.create!(author_kind: 'assistant', status: 'done', parent: parent, meta: { 'asked_by' => @requester.id, 'trigger_id' => trigger.id })
    TeamChat::Run.for_reply!(reply).update!(configuration: { 'engine' => 'openai', 'model' => 'activity-test-model' })
    action = TeamChat::Actions.propose!(reply, tool: tool, arguments: args, proposed_for: @requester)
    Current.user = @approver
    TeamChat::Actions.decide!(reply, action['id'], user: @approver, approve: true)
    approval = TeamChat::Approval.find_by!(public_id: action['id'])
    [approval, trigger]
  end

  def sign_in(user = @approver, password: 'password123')
    post login_path, params: { email: user.email, password: password }
  end

  def create_ai_task
    approval, trigger = approve('create_task', { 'title' => 'AI activity verification' }, 'PRIVATE ORIGINAL REQUEST: please create this task')
    @task = Projects::Task.find(approval.events.find_by!(kind: 'executed').details.dig('result', 'id'))
    [approval, trigger]
  end

  test 'creation update and closure show requester model harness exact times and source messages' do
    created, first = create_ai_task
    updated, second = approve('update_task', { 'task_id' => @task.id, 'priority' => 'high' }, 'PRIVATE ORIGINAL REQUEST: raise its priority')
    closed, third = approve('update_task', { 'task_id' => @task.id, 'status' => 'done' }, 'PRIVATE ORIGINAL REQUEST: close this task')
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history [data-ai-activity]', count: 3
    ['AI created task', 'AI updated task', 'AI closed task'].each { |label| assert_select '#history p', text: label }
    Current.tenant = @tenant
    [created, updated, closed].each do |record|
      log = ActivityLog.where(action: 'team_chat_action').detect { |entry| JSON.parse(entry.details)['approval_id'] == record.id }
      assert_select "#history [data-ai-activity='#{log.id}']" do
        assert_select 'dt', text: 'Requested by'
        assert_select 'dd', text: @requester.display_name
        assert_select 'dt', text: 'Approved by'
        assert_select 'dd', text: @approver.display_name
        assert_select 'dd', text: 'activity-test-model'
        assert_select 'dd', text: "TeamChat::Agent · RubyLLM #{RubyLLM::VERSION}"
        assert_select 'time[datetime=?]', Time.iso8601(record.provenance['requested_at']).in_time_zone.iso8601(6)
        assert_select 'time[datetime=?]', log.created_at.iso8601(6)
      end
    end
    [first, second, third].each do |message|
      assert_select '#history a[href=?]', team_chat_room_path(@room.slug, message: message.id), text: 'View source message'
    end
    assert_select '#history', text: /(?:EST|EDT|UTC)/
    assert_select '#history', text: /Priority|priority/
    assert_select '#history', text: /moved to done/
    assert_select '#history', text: /PRIVATE ORIGINAL REQUEST/, count: 0
    assert_select '#history', text: /"approval_id"|"requester_name"/, count: 0
    assert_nil @task.reload.assignee_id
  end

  test 'source links open the exact message inside its thread' do
    root = @room.messages.create!(author_kind: 'person', user: @requester, body: 'Thread root')
    approval, trigger = approve('create_task', { 'title' => 'Thread task' }, 'Create this inside the thread', parent: root)
    @task = Projects::Task.find(approval.events.find_by!(kind: 'executed').details.dig('result', 'id'))
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history a[href=?]', team_chat_room_path(@room.slug, message: trigger.id, thread: root.id), text: 'View source message'
  end

  test 'task readers cannot get links or chat bodies from someone else private room' do
    create_ai_task
    @room.update!(kind: 'direct')
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history [data-ai-activity] dd', text: 'Private or unavailable chat'
    assert_select '#history a[href*="/chat/"]', count: 0
    assert_select '#history', text: /PRIVATE ORIGINAL REQUEST/, count: 0
    assert_select '#history dd', text: @requester.display_name
  end

  test 'employees assigned a task see attribution without gaining chat access' do
    create_ai_task
    employee = User.create!(tenant: @tenant, name: 'Assigned employee', email: 'activity-employee@example.com', role: 'employee', password: 'password123')
    @task.update!(assignee_id: employee.id)
    sign_in(employee)
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history dd', text: 'activity-test-model'
    assert_select '#history a[href*="/chat/"]', count: 0
    assert_select '#history', text: /PRIVATE ORIGINAL REQUEST/, count: 0
  end

  test 'a visible source link cannot carry over to an inaccessible activity entry' do
    create_ai_task
    @room.update!(kind: 'direct')
    @room = TeamChat::Room.create!(name: 'Shared source', slug: 'shared-activity', kind: 'channel', created_by: @requester, assistant_mode: 'off')
    approve('update_task', { 'task_id' => @task.id, 'priority' => 'high' }, 'Shared request')
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history [data-ai-activity]', count: 2
    assert_select '#history a', text: 'View source message', count: 1
    assert_select '#history dd', text: 'Private or unavailable chat', count: 1
  end

  test 'deleted source messages show unavailable instead of a broken or private link' do
    _approval, trigger = create_ai_task
    trigger.soft_delete!
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history a[href*="/chat/"]', count: 0
    assert_select '#history dd', text: 'Private or unavailable chat'
  end

  test 'untrusted audit text is escaped and stored URLs are never used as links' do
    create_ai_task
    log = ActivityLog.for_subject('Projects::Task', @task.id).find_by!(action: 'team_chat_action')
    data = JSON.parse(log.details)
    data['source']['model'] = '<script>alert(1)</script>'
    data['source']['requester_name'] = '<img src=x onerror=alert(1)>'
    data['source']['chat_url'] = 'javascript:alert(1)'
    log.update!(details: JSON.generate(data))
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history script, #history img, #history a[href^="javascript:"]', count: 0
    assert_select '#history dd', text: '<script>alert(1)</script>'
    assert_select '#history a', text: 'View source message'
  end

  test 'ordinary human activity keeps its readable text and has no invented AI fields' do
    @task = Projects::Task.create!(title: 'Human task')
    ActivityLogger.log('task_updated', subject: @task, actor: @requester, details: 'Priority changed by a person')
    sign_in
    get projects_task_path(@task)
    assert_select '#history', text: /Priority changed by a person/
    assert_select '#history [data-ai-activity]', count: 0
    assert_select '#history dt', text: 'Model', count: 0
  end

  test 'malformed legacy payloads and unknown metadata are displayed without raw JSON or exceptions' do
    @task = Projects::Task.create!(title: 'Legacy task')
    ['tool=create_task; outcome=done', '[]', '{broken', '{"source":{"room_id":{},"trigger_id":[],"requested_at":"bad date"},"approval_id":999999999999999999999999}'].each do |details|
      ActivityLogger.log('team_chat_action', subject: @task, actor: @requester, details: details)
    end
    sign_in
    get projects_task_path(@task)
    assert_response :success
    assert_select '#history [data-ai-activity]', count: 4
    assert_select '#history dd', text: 'Not recorded', minimum: 4
    assert_select '#history a', count: 0
    assert_select '#history', text: /tool=create_task|broken|room_id/, count: 0
  end
end
