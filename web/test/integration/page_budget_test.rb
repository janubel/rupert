# frozen_string_literal: true

require 'test_helper'

# A query budget for the pages people open most. A page that starts asking the
# database once per row (N+1) or rebuilds shared data per call trips this long
# before anyone feels it. Raise a budget only with a reason in the commit.
class PageBudgetTest < ActionDispatch::IntegrationTest
  IGNORED = %w[SCHEMA TRANSACTION].freeze
  SHELL = 14 # queries any signed-in page may spend on the shell (user, permissions, status bar, rail)

  BUDGETS = {
    root_path: 45, sales_path: 40, inventory_index_path: 40, customers_path: 35, bookkeeping_path: 45,
    finance_expenses_path: 35, finance_cash_flow_path: 45, people_employees_path: 35, people_team_schedule_path: 30,
    people_scheduled_shifts_path: 30, people_timesheets_path: 50, projects_tasks_path: 35, connections_path: 90,
    system_path: 45, notifications_path: SHELL + 6, books_desk_path: 120, reports_path: 40
  }.freeze

  setup do
    @admin = users(:regular_user)
    @admin.update!(role: 'super_admin')
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  test 'main pages stay within their query budget' do
    counts = {}
    over = BUDGETS.filter_map do |helper, budget|
      path = public_send(helper)
      count = counts[path] = count_queries { get path }
      assert_includes [200, 302], response.status, "#{path} answered #{response.status}"
      "#{path}: #{count} queries (budget #{budget})" if count > budget
    end
    puts counts.map { |path, count| "#{path} #{count}" }.join(' · ') if ENV['BUDGET_REPORT'] == '1'
    assert_empty over, "Pages over budget:\n#{over.join("\n")}"
  end

  private

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:cached] || IGNORED.include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    count
  end
end
