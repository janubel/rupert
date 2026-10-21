# frozen_string_literal: true

require 'test_helper'

# Pages converted to the shared page_header: one header, one h1, a matching tab title.
class PageHeaderPagesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  teardown { Current.reset }

  {
    'Add staff member' => :new_user_path,
    'Record expense' => :new_finance_expense_path,
    'Alerts' => :alerts_path,
    'New goal' => :new_goals_goal_path,
    'New department' => :new_people_department_path,
    'Add location' => :new_location_path
  }.each do |heading, route|
    test "#{heading} uses the shared header and tab title" do
      get public_send(route)
      assert_response :success
      assert_select 'header.page-header h1.page-title', count: 1, text: heading
      assert_select 'h1', count: 1
      assert_select 'title', /\A#{Regexp.escape(heading)} · /
    end
  end

  test 'form pages use the narrow width tier instead of ad-hoc max-w classes' do
    get new_user_path
    assert_select '.card.page-narrow'
    assert_select '.card.max-w-xl', count: 0
  end
end
