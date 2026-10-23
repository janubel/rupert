# frozen_string_literal: true

require 'test_helper'

# First-run welcome, the getting-started checklist, page tours, the help panel
# and the team training view. Every write touches only the signed-in account.
class LearningOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @user = users(:regular_user)
    @user.update!(dashboard_config: nil, name: 'Dana Admin')
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  test 'a brand new account sees the welcome on the dashboard and choosing a path records it' do
    get root_path
    assert_response :success
    assert_select 'aside#welcome[aria-label="Getting started"]'
    assert_select '#welcome .eyebrow', text: /Welcome to Rupert, Dana/
    assert_select '#welcome button.path-card[name="focus"]', minimum: 3
    assert_select '#welcome a[href=?]', learning_path('start')
    assert_select 'aside#getting-started', count: 0

    post onboard_path, params: { focus: 'stock', next: 'tour' }
    assert_redirected_to "#{root_path}?tour=1"
    config = @user.reload.dashboard_config_hash
    assert_equal 'stock', config['learning_focus']
    assert config['learning_welcomed_at'].present?

    follow_redirect!
    assert_response :success
    assert_select 'aside#welcome', count: 0
    assert_select 'aside#getting-started[aria-label="Getting started"]'
    assert_select '[data-controller~="tour"][data-tour-key-value="dashboard"][data-tour-autostart-value="true"]'
  end

  test 'skipping the welcome records it without choosing a path and never changes permissions' do
    post onboard_path, params: { role: 'super_admin', learning_completed: ['books'] }
    assert_redirected_to root_path
    config = @user.reload.dashboard_config_hash
    assert config['learning_welcomed_at'].present?
    assert_nil config['learning_focus']
    assert_nil config['learning_completed']
    assert_equal 'admin', @user.role
    get root_path
    assert_select 'aside#welcome', count: 0
    assert_select 'aside#getting-started'
  end

  test 'an unknown path is rejected' do
    post onboard_path, params: { focus: 'platform_takeover' }
    assert_redirected_to welcome_path
    assert_nil @user.reload.dashboard_config_hash['learning_focus']
  end

  test 'the standalone welcome page explains areas, paths and the first week' do
    get welcome_path
    assert_response :success
    assert_select 'h1', text: /Rupert, in the time it takes/
    assert_select 'button.path-card', minimum: 3
    assert_select '#welcome-areas-title'
    assert_select '.checklist-item', minimum: 4
  end

  test 'the first-week checklist detects real progress and accepts manual marks' do
    @user.update!(dashboard_config: { 'learning_welcomed_at' => Time.current.iso8601 })
    get root_path
    assert_select '#getting-started .eyebrow', text: /0 of \d+ done/
    assert_select '#getting-started progress[value="0"]'

    patch learning_preferences_path, params: { checklist: 'check_day' }
    assert_response :redirect
    assert_equal ['check_day'], @user.reload.dashboard_config_hash['learning_checklist_done']

    patch learning_preferences_path, params: { checklist: 'not_a_real_item' }
    assert_response :unprocessable_entity
    assert_equal ['check_day'], @user.reload.dashboard_config_hash['learning_checklist_done']

    post complete_learning_path('start'), params: { answers: { '0' => '1', '1' => '1' } }
    get root_path
    assert_select '#getting-started .eyebrow', text: /2 of \d+ done/

    patch learning_preferences_path, params: { checklist_hidden: '1' }
    get root_path
    assert_select 'aside#getting-started', count: 0
    get learning_index_path
    assert_select '#first-week'
    assert_select 'form[action=?] input[name="checklist_hidden"][value="0"]', learning_preferences_path
    patch learning_preferences_path, params: { checklist_hidden: '0' }
    get root_path
    assert_select 'aside#getting-started'
  end

  test 'work pages offer a tour that is recorded per account over JSON' do
    get sales_path
    assert_response :success
    assert_select '[data-controller~="tour"][data-tour-key-value="sales"]'
    assert_select '[data-tour="filters"]'
    assert_select '[data-tour="summary"]'
    assert_select '[data-tour="journal"]'
    assert_select 'details.workspace-help:not([open])'
    assert_select '#page-guide-panel h3', text: 'Take a look around'
    assert_select 'button[data-tour-target="trigger"][hidden]'
    assert_select '.help-bar [data-tour-target="badge"]', text: 'New'

    patch learning_preferences_path, params: { tour: 'sales' }, as: :json
    assert_response :success
    assert_equal ['sales'], JSON.parse(response.body)['tours']
    assert_equal ['sales'], @user.reload.dashboard_config_hash['learning_tours']

    get sales_path
    assert_select '[data-tour-done-value="true"]'
    assert_select '.help-bar [data-tour-target="badge"]', count: 0

    patch learning_preferences_path, params: { tour: 'made_up' }, as: :json
    assert_response :unprocessable_entity
  end

  test 'tours respect permissions and staff accounts only see their own' do
    @user.update!(role: 'reader')
    patch learning_preferences_path, params: { tour: 'employee_home' }, as: :json
    assert_response :unprocessable_entity
    get sales_path
    assert_select '[data-tour-key-value="sales"]'

    @user.update!(role: 'employee')
    assert_equal %w[employee_home learning], PageTours.available(@user.reload).map(&:key).sort.then { |keys| keys & %w[employee_home learning] }
    assert_not_includes PageTours.available(@user).map(&:key), 'sales'
    get employee_app_path
    assert_response :success
    assert_select '[data-tour="nav"]'
  end

  test 'the help panel and ? button render on management and staff layouts' do
    get inventory_index_path
    assert_select 'footer a[aria-label="Help"][href=?]', learning_index_path
    assert_select 'aside.help-panel[role="dialog"] #help-panel-search'
    assert_select '.help-panel button', text: /Show me around/
    assert_select '.help-panel a[href=?]', learning_path('stock')
    assert_select '.help-panel a[href=?]', learning_team_path

    @user.update!(role: 'employee')
    get employee_app_path
    assert_select 'a.nav-utility[aria-label="Help"]'
    assert_select 'aside.help-panel'
    assert_select '.help-panel a[href=?]', learning_team_path, count: 0
  end

  test 'help search returns permitted lessons, definitions and tours as JSON' do
    get learning_index_path(format: :json), params: { q: 'cover' }
    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body['lessons'].map { |lesson| lesson['key'] }, 'alerts'
    assert_includes body['terms'].map { |term| term['key'] }, 'days_of_cover'
    assert body['tours'].is_a?(Array)

    @user.update!(role: 'employee')
    get learning_index_path(format: :json), params: { q: 'cover' }
    body = JSON.parse(response.body)
    assert_not_includes body['lessons'].map { |lesson| lesson['key'] }, 'alerts'
    assert_not_includes body['tours'].map { |tour| tour['key'] }, 'alerts'
  end

  test 'definitions and live calculations sit beside the numbers' do
    get root_path
    assert_select '#dashboard-widget-stats details.term[data-term="sales_total"] summary'
    assert_select '#today-sales-calculation.calculation summary', text: /What’s in this total\?/
    assert_select '#today-sales-calculation dd', text: /Recorded sales today|\$/

    get alerts_path
    assert_select 'th details.term[data-term="days_of_cover"]'
    assert_select 'th details.term[data-term="suggested_reorder"]'
  end

  test 'the alerts calculation uses the first alert with recent sales' do
    Current.tenant = @user.tenant
    alert = StockAlert.create!(sku: 'LRN-1', quantity: 3, threshold: 5, status: 'open', tenant_id: @user.tenant_id)
    row = RestockAdvisor::Row.new(alert: alert, sku: 'LRN-1', shop_qty: 2, pos_qty: 4, sold_14: 10, sold_30: 30, days_of_cover: 6.0, suggested_qty: 24)
    RestockAdvisor.stubs(:for_alerts).returns({ alert.id => row })
    get alerts_path
    assert_response :success
    assert_select '#alert-calculation dt', text: /On hand: 2 shop \+ 4 POS/
    assert_select '#alert-calculation dd', text: '6 units'
    assert_select '#alert-calculation dd', text: '24 units'
    assert_select '#alert-calculation a[href=?]', learning_path('alerts', anchor: 'lesson-example')
  end

  test 'lessons with a practice calculator and common mistakes render them' do
    get learning_path('alerts')
    assert_response :success
    assert_select '#lesson-try[data-controller="practice"][data-practice-kind-value="cover"]'
    assert_select '#mistakes-title'
    assert_select 'fieldset.quiz-question', count: 3
    assert_select 'a[href=?]', "/alerts?tour=1"
  end

  test 'completing every lesson in a path reports the module as complete' do
    patch learning_preferences_path, params: { focus: 'tasks' }
    post complete_learning_path('start'), params: { answers: { '0' => '1', '1' => '1' } }
    post complete_learning_path('tasks'), params: { answers: { '0' => '1' } }
    assert_redirected_to learning_index_path
    assert_match(/finished “Find and update my tasks”/, flash[:notice])
    get learning_index_path
    assert_select '.module-badge', text: /Find and update my tasks/
  end

  test 'team training progress is read-only and needs account or HR access' do
    other = User.create!(tenant: @user.tenant, email: 'learner@example.test', password: 'password123', role: 'cashier', name: 'Casey Till',
      dashboard_config: { 'learning_focus' => 'checkout', 'learning_completed' => %w[start checkout], 'learning_welcomed_at' => Time.current.iso8601 })
    get learning_team_path
    assert_response :success
    assert_select 'h1', text: 'Team training progress'
    assert_select 'td', text: /Casey Till/
    assert_select 'td', text: /Serve customers/
    assert_select 'main form', count: 0

    @user.update!(role: 'reader')
    get learning_team_path
    assert_response :forbidden

    @user.update!(role: 'employee')
    get learning_team_path
    assert_response :redirect
    assert_nil other.reload.dashboard_config_hash['learning_tours']
  end

  test 'a staff account gets the staff welcome and tour on its home page' do
    @user.update!(role: 'employee')
    get employee_app_path
    assert_response :success
    assert_select 'aside#welcome button.path-card[value="staff"]'
    post onboard_path, params: { focus: 'staff', next: 'tour' }
    assert_redirected_to "#{employee_app_path}?tour=1"
    follow_redirect!
    assert_select '[data-tour-key-value="employee_home"]'
    assert_select '#getting-started .checklist-item', minimum: 3
  end

  test 'signed-out requests cannot read or write onboarding state' do
    delete logout_path
    get welcome_path
    assert_redirected_to login_path
    post onboard_path, params: { focus: 'stock' }
    assert_redirected_to login_path
    patch learning_preferences_path, params: { tour: 'sales' }, as: :json
    assert_response :redirect
    get learning_team_path
    assert_redirected_to login_path
  end
end
