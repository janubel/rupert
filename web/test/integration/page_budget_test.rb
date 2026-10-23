# frozen_string_literal: true

require 'test_helper'

# A query budget for the pages people open most. A page that starts asking the
# database once per row (N+1) or rebuilds shared data per call trips this long
# before anyone feels it. Raise a budget only with a reason in the commit.
class PageBudgetTest < ActionDispatch::IntegrationTest
  IGNORED = %w[SCHEMA TRANSACTION].freeze
  SHELL = 14 # queries any signed-in page may spend on the shell (user, permissions, status bar, rail)

  BUDGETS = {
    '/' => 45, '/sales' => 40, '/inventory' => 40, '/customers' => 35, '/bookkeeping' => 45,
    '/finance/expenses' => 35, '/finance/cash_flow' => 45, '/people/employees' => 35, '/people/team_schedule' => 30,
    '/people/scheduled_shifts' => 30, '/people/timesheets' => 50, '/projects/tasks' => 35, '/connections' => 90,
    '/system' => 45, '/notifications' => SHELL + 6, '/books_desk' => 120, '/reports' => 40
  }.freeze

  setup do
    @admin = users(:regular_user)
    @admin.update!(role: 'super_admin')
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  test 'main pages stay within their query budget' do
    over = BUDGETS.filter_map do |path, budget|
      count = count_queries { get path }
      assert_includes [200, 302], response.status, "#{path} answered #{response.status}"
      "#{path}: #{count} queries (budget #{budget})" if count > budget
    end
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
