# frozen_string_literal: true

require 'test_helper'

# The ladybug sits in the header of both layouts for every signed-in person and
# nowhere else, and the panel is a labelled dialog.
class FeedbackPanelLayoutTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def sign_in(role)
    user = User.create!(email: "#{role}-panel@example.com", password: 'password123', role: role, tenant_id: @tenant.id, name: role.humanize)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def assert_ladybug
    assert_select "a[data-feedback-target='trigger'][aria-haspopup='dialog'][aria-label]", 1
    assert_select "aside#feedback-panel[role='dialog'][aria-modal='true'][aria-labelledby='feedback-title']", 1
    assert_select '#feedback-title', 'Tell the Rupert team'
    assert_select "input[type='radio'][name='feedback_kind']", 3
    assert_select "textarea#feedback-description[required][maxlength='#{AgentFeedback::DETAILS_MAX}']", 1
    assert_select "label[for='feedback-description']", 1
    assert_select "[data-controller~='feedback'][data-feedback-url-value='#{feedback_reports_path}']", 1
    assert_select "[data-feedback-request-id-value]:not([data-feedback-request-id-value=''])", 1
  end

  test 'a signed-in administrator sees the ladybug in the header' do
    sign_in('admin')
    get dashboard_path
    assert_response :success
    assert_select '.header-utilities a[data-feedback-target="trigger"]', 1
    assert_ladybug
  end

  test 'a cashier sees it and so does a time-clock-only account' do
    sign_in('cashier')
    get dashboard_path
    assert_ladybug

    delete logout_path
    sign_in('employee')
    get employee_app_path
    assert_response :success
    assert_ladybug
  end

  test 'the login page has no ladybug' do
    get login_path
    assert_response :success
    assert_select 'aside#feedback-panel', 0
    assert_select "[data-feedback-target='trigger']", 0
  end

  test 'the screenshot library is lazy: pinned without preload' do
    sign_in('admin')
    get dashboard_path
    assert_includes response.body, '"html2canvas-pro"'
    assert_select "link[rel='modulepreload'][href*='html2canvas']", 0
  end
end
