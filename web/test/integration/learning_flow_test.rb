# frozen_string_literal: true

require 'test_helper'

class LearningFlowTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

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
    assert_select 'h2', text: 'Your hours and receipts'
    assert_select 'h2', text: 'Understand stock before acting', count: 0
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
  end
end
