# frozen_string_literal: true

require 'test_helper'

# The Next thing to do bar: what needs this person now, most urgent first.
class NextThingsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
  end

  teardown { Current.reset }

  def keys(user = @user) = NextThings.for(user).pluck(:key)

  test 'a failing sync comes before an overdue task, and each item links to the page that fixes it' do
    task = Projects::Task.create!(title: 'Count the tea shelf', assignee: @user, due_on: Date.current - 2)
    SyncAttempt.create!(source: 'swipesimple', operation: 'web', status: 'succeeded', queued_at: 2.days.ago, finished_at: 2.days.ago)
    SyncAttempt.create!(source: 'swipesimple', operation: 'web', status: 'failed', queued_at: 1.hour.ago, finished_at: 1.hour.ago, error_category: 'identity')
    items = NextThings.for(@user)
    sync = items.find { |item| item[:key] == 'sync:swipesimple:web' }
    mine = items.find { |item| item[:key] == "task:#{task.id}" }
    assert sync && mine
    assert_operator items.index(sync), :<, items.index(mine)
    assert_equal ['SwipeSimple web sync is failing', 'fix', '/syncs'], sync.values_at(:title, :level, :path)
    assert_equal ['Count the tea shelf', 'Due ' + (Date.current - 2).strftime('%b %-d') + ', 2 days late', "/projects/tasks/#{task.id}"],
      mine.values_at(:title, :detail, :path)
    assert(items.each_cons(2).all? { |a, b| NextThings::LEVELS[a[:level]] <= NextThings::LEVELS[b[:level]] }, 'fix before watch')
  end

  test 'done hides an item until it changes; a problem marked done comes back after 12 hours' do
    task = Projects::Task.create!(title: 'Send the invoice', assignee: @user, due_on: Date.current - 1)
    key = "task:#{task.id}"
    assert NextThings.new(@user).dismiss!(key, 'done')
    refute_includes keys, key
    travel 13.hours do
      assert_includes keys, key, 'a fix item comes back if it is still open'
    end
    task.update!(due_on: Date.current - 3) # the item changed: it shows again at once
    assert_includes keys, key
  end

  test 'snooze hides an item for an hour whatever happens' do
    task = Projects::Task.create!(title: 'Call the supplier', assignee: @user, due_on: Date.current - 1)
    key = "task:#{task.id}"
    NextThings.new(@user).dismiss!(key, 'snooze')
    task.update!(due_on: Date.current - 4)
    refute_includes keys, key
    travel 61.minutes do
      assert_includes keys, key
    end
  end

  test 'people only see what they may act on: an employee sees their own late and due-today tasks' do
    worker = User.create!(tenant: @tenant, email: 'next-worker@example.com', name: 'Next worker', role: 'employee', password: 'password123')
    worker.update_permission_overrides!(%w[tasks.self])
    late = Projects::Task.create!(title: 'Restock the front', assignee: worker, due_on: Date.current - 1)
    today = Projects::Task.create!(title: 'Face the shelves', assignee: worker, due_on: Date.current)
    Projects::Task.create!(title: 'Someone else', assignee: @user, due_on: Date.current - 1)
    SyncAttempt.create!(source: 'shopify', operation: 'catalog', status: 'failed', queued_at: 1.hour.ago, finished_at: 1.hour.ago, error_category: 'network')
    items = NextThings.for(worker)
    assert_equal ["task:#{late.id}", "task:#{today.id}"], items.pluck(:key)
    assert_equal %w[fix watch], items.pluck(:level)
    assert_equal 'Due today', items.last[:detail]
  end

  test 'only items the person can see can be dismissed' do
    refute NextThings.new(@user).dismiss!('task:999999', 'done')
    assert_equal 0, NextThingDismissal.count
  end
end
