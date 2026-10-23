# frozen_string_literal: true

require 'test_helper'

# The Next thing to do bar and ops mode.
class NextThingsIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:regular_user)
    Current.set(tenant: @admin.tenant) do
      @first = Projects::Task.create!(title: 'Approve the timesheets', assignee: @admin, due_on: Date.current - 2, priority: 'high')
      @second = Projects::Task.create!(title: 'Order more bags', assignee: @admin, due_on: Date.current - 1)
    end
    # Only the two tasks: the other sources are covered in test/services/next_things_test.rb.
    %i[sync_items queue_items alert_items compliance_items].each { |source| NextThings.any_instance.stubs(source).returns([]) }
    sign_in(@admin)
  end

  def sign_in(user, password: 'password')
    post login_path, params: { email: user.email, password: password }
  end

  test 'every page loads the bar into its own frame after the page' do
    get root_path
    follow_redirect! while response.redirect?
    assert_select "turbo-frame#next_thing[src='#{next_thing_path}'][loading=lazy]"
  end

  test 'the bar shows the most urgent item with its page, and Done moves on' do
    get next_thing_path
    assert_response :success
    assert_select 'turbo-frame#next_thing .next-bar' do
      assert_select '.pill-rose', 'Fix'
      assert_select "a.next-bar-link[href='/projects/tasks/#{@first.id}'][data-turbo-frame=_top]", 'Approve the timesheets'
      assert_select 'button', 'Done'
      assert_select 'button', 'Snooze 1 h'
      assert_select 'button', /Start ops mode · 2/
    end
    post done_next_thing_path, params: { key: "task:#{@first.id}" }
    assert_redirected_to next_thing_path
    follow_redirect!
    assert_select 'a.next-bar-link', 'Order more bags'
  end

  test 'ops mode works the list one at a time; skip goes round, exit returns to the quiet bar' do
    post mode_next_thing_path, params: { ops: 1 }
    follow_redirect!
    assert_select '.next-bar-ops .next-bar-label', /Ops mode · 1 of 2/
    assert_select '.next-bar-ops strong', 'Approve the timesheets'
    assert_select ".next-bar-ops a[href='/projects/tasks/#{@first.id}']", 'Open'
    post skip_next_thing_path, params: { key: "task:#{@first.id}" }
    follow_redirect!
    assert_select '.next-bar-label', /2 of 2/
    post skip_next_thing_path, params: { key: "task:#{@second.id}" }
    follow_redirect!
    assert_select '.next-bar-label', /1 of 2/, 'after the last one it starts again from the top'
    post snooze_next_thing_path, params: { key: "task:#{@first.id}" }
    post snooze_next_thing_path, params: { key: "task:#{@second.id}" }
    get next_thing_path
    assert_select '.next-bar-ops', /All clear/
    post mode_next_thing_path, params: { ops: 0 }
    follow_redirect!
    assert_select '.next-bar', 0, 'nothing waiting: the quiet bar is empty'
  end

  test 'an employee gets the bar in the employee app with only their own tasks' do
    tenant = @admin.tenant
    worker = User.create!(tenant: tenant, email: 'next-employee@example.com', password: 'password123', role: 'employee')
    worker.update_permission_overrides!(%w[tasks.self])
    Current.set(tenant: tenant) { People::Employee.create!(first_name: 'Sam', last_name: 'Floor', user: worker) }
    mine = Current.set(tenant: tenant) { Projects::Task.create!(title: 'Restock the tea wall', assignee: worker, due_on: Date.current - 1) }
    delete logout_path
    post login_path, params: { email: worker.email, password: 'password123' }
    get employee_app_path
    assert_response :success
    assert_select "turbo-frame#next_thing[src='#{next_thing_path}']"
    get next_thing_path
    assert_response :success
    assert_select "a.next-bar-link[href='/projects/tasks/#{mine.id}']", 'Restock the tea wall'
    assert_select 'a.next-bar-link', count: 1
    assert_no_match 'Approve the timesheets', response.body, "another person's task never shows"
    post done_next_thing_path, params: { key: "task:#{mine.id}" }
    follow_redirect!
    assert_select '.next-bar', 0
  end
end
