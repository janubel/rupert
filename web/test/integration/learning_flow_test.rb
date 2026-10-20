# frozen_string_literal: true

require 'test_helper'

class LearningFlowTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  test 'correct answers save only personal progress and preserve dashboard preferences' do
    @user.update!(dashboard_config: { 'hidden' => ['stats'] })
    post complete_learning_path('stock'), params: { answer: '0' }
    assert_response :unprocessable_entity
    assert_nil @user.reload.dashboard_config_hash['learning_completed']
    post complete_learning_path('stock'), params: { answer: '2', user_id: 'another-user' }
    assert_redirected_to learning_index_path
    assert_equal ['stock'], @user.reload.dashboard_config_hash['learning_completed']
    assert_equal ['stats'], @user.dashboard_config_hash['hidden']
    post complete_learning_path('stock'), params: { answer: '2' }
    assert_equal ['stock'], @user.reload.dashboard_config_hash['learning_completed']
  end

  test 'dashboard reset preserves learning progress' do
    @user.update!(dashboard_config: { 'learning_completed' => ['start'], 'hidden' => ['stats'] })
    post customize_dashboard_path, params: { reset: true }
    assert_response :success
    assert_equal ['start'], @user.reload.dashboard_config_hash['learning_completed']
    assert_nil @user.dashboard_config_hash['hidden']
  end

  test 'lessons are permission checked on reads and writes' do
    @user.update!(role: 'employee')
    get learning_index_path
    assert_response :success
    assert_select '#lessons h3', text: 'Your hours and receipts'
    assert_select '#lessons h3', text: 'Understand stock before acting', count: 0
    get learning_path('stock')
    assert_response :not_found
    post complete_learning_path('stock'), params: { answer: '2' }
    assert_response :not_found
    get learning_path('staff')
    assert_response :success
    post complete_learning_path('staff'), params: { answer: '1' }
    assert_redirected_to learning_index_path
  end

  test 'glossary searches definitions and escapes query text' do
    get learning_index_path, params: { q: 'shared stock' }
    assert_response :success
    assert_select '#term-shared_stock'
    assert_select '#term-kpi', count: 0
    get learning_path('missing')
    assert_response :not_found
    get learning_index_path, params: { q: '<script>alert(1)</script>' }
    assert_response :success
    assert_select 'script', text: 'alert(1)', count: 0
    assert_includes response.body, '&lt;script&gt;'
  end

  test 'a personal path recommends the next unfinished step and survives sign in' do
    patch learning_preferences_path, params: { focus: 'stock', user_id: 'someone-else' }
    assert_redirected_to learning_index_path
    assert_equal 'stock', @user.reload.dashboard_config_hash['learning_focus']
    post complete_learning_path('start'), params: { answer: '1' }
    post login_path, params: { email: @user.email, password: 'password' }
    get learning_index_path
    assert_select '#path-title', text: 'Look after stock'
    assert_select '#your-path a.btn-primary[href=?]', learning_path('stock'), text: 'Start next step'
    assert_select 'progress[value="1"][max="3"]'
  end

  test 'welcome dismissal is personal and a dashboard reset preserves all learning preferences' do
    other = User.create!(tenant: @user.tenant, email: 'other-learner@example.test', password: 'password123', role: 'admin')
    patch learning_preferences_path, params: { focus: 'stock' }
    patch learning_preferences_path, params: { dismiss: '1', user_id: other.id }
    assert_redirected_to root_path
    assert @user.reload.dashboard_config_hash['learning_welcome_hidden']
    assert_nil other.reload.dashboard_config_hash['learning_welcome_hidden']
    post customize_dashboard_path, params: { reset: true }
    assert_equal 'stock', @user.reload.dashboard_config_hash['learning_focus']
    assert @user.dashboard_config_hash['learning_welcome_hidden']
    patch learning_preferences_path, params: { focus: 'staff' }
    assert_equal false, @user.reload.dashboard_config_hash['learning_welcome_hidden']
  end

  test 'employees cannot select an administrative path or supply arbitrary profile data' do
    @user.update!(role: 'employee')
    patch learning_preferences_path, params: { focus: 'setup', learning_completed: ['setup'], role: 'admin' }
    assert_response :unprocessable_entity
    assert_empty @user.reload.dashboard_config_hash
    get learning_index_path
    assert_select '#path-title', text: 'Manage my hours and receipts'
    assert_select 'select[name="focus"] option[value="setup"]', count: 0
    patch learning_preferences_path, params: { dismiss: '1' }
    assert_redirected_to employee_app_path
    get employee_app_path
    assert_response :success
    assert_select 'aside[aria-label="Getting started"]', count: 0
    assert_select 'a[href=?]', learning_index_path
  end

  test 'all available lessons have examples and usable workspace destinations' do
    LearningCatalog.available(@user).each do |lesson|
      get learning_path(lesson[:key])
      assert_response :success
      assert_select '#lesson-example h2', text: LearningExamples.for(lesson[:key])[:title]
      assert_select 'form#lesson-practice'
      assert Rails.application.routes.recognize_path(lesson[:destination], method: :get)
    end
  end

  test 'first run offers learning instead of a credential form to readers' do
    @user.update!(role: 'reader')
    OnboardingController.stubs(:configured?).returns(false)
    get onboarding_path
    assert_response :success
    assert_select 'form[action=?]', onboarding_connect_path, count: 0
    assert_select 'a[href=?]', learning_index_path
    assert_select 'h1', text: 'Start with your everyday work'
  end

  test 'contextual help starts closed and stock definitions are on the rendered workspace' do
    get inventory_index_path
    assert_response :success
    assert_select 'details.workspace-help:not([open])'
    assert_select 'summary', text: 'How to read these stock numbers'
    assert_select 'dd', text: LearningCatalog::TERMS.fetch('promise').last
    get inventory_counts_path
    assert_select 'a[href=?]', learning_path('counts')
  end

  test 'live sales explanations use the same selected data as the summary' do
    Current.tenant = @user.tenant
    [3000, 2000].each_with_index do |cents, index|
      order = Core::Order.create!(source: 'shopify', source_order_id: "learning-total-#{index}", order_number: "L#{index}",
        occurred_at: Time.current, gross_cents: cents, currency: 'USD', tenant_id: @user.tenant_id)
      order.mark_paid!
    end
    Core::Order.create!(source: 'shopify', source_order_id: 'learning-total-pending', order_number: 'LP',
      occurred_at: Time.current, gross_cents: 90000, currency: 'USD', tenant_id: @user.tenant_id)
    get sales_path, params: { source: 'shopify', status: 'placed' }
    assert_response :success
    assert_select '[data-sales-total-explanation] dd', text: 'USD 50.00'
    assert_select '[data-sales-total-explanation] p', text: /Average sale = USD 50.00 ÷ 2 included sales = USD 25.00/
  end

  test 'signed out requests cannot read or write personal learning state' do
    delete logout_path
    get learning_index_path
    assert_redirected_to login_path
    post complete_learning_path('start'), params: { answer: '1' }
    assert_redirected_to login_path
    patch learning_preferences_path, params: { focus: 'stock' }
    assert_redirected_to login_path
  end
end
