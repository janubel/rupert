# frozen_string_literal: true

require 'test_helper'

# Test questions: people who know the books tune the questions that score the bots.
class TeamChatQuestionsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  def edits = Current.set(tenant: @admin.tenant) { TeamChat::BatteryQuestion.all.to_a }
  def items(set) = Current.set(tenant: @admin.tenant) { TeamChat::Battery.items(TeamChat::Battery.config_for(set)) }

  test 'every set is listed with its built-in questions, checks and a run button' do
    get team_chat_questions_path(set: 'finance')
    assert_response :success
    assert_select 'nav.tabs a', /General/
    assert_select 'nav.tabs a.tab-active', 'Finance'
    assert_select 'tr#q-f22 strong', 'How much money has the store made today?'
    assert_select 'tr#q-f22 code', 'daily_close'
    assert_select 'tr#q-f22 .pill-taupe', 'Built-in'
    assert_select 'input[type=submit][value="Run these questions"]'
    get team_chat_scores_path
    assert_select "a[href='#{team_chat_questions_path}']", 'Open test questions'
  end

  test 'adding, editing, removing and restoring change only this workspace and score the edited set apart' do
    post team_chat_questions_path(set: 'finance'), params: { question: 'What did the register take in cash yesterday?',
      expect: 'Cash per store from daily_close.', cadence: 'daily', checks: "daily_close from=yesterday.from to=yesterday.to" }
    added = edits.sole
    assert_equal ['w1', [{ 'tool' => 'daily_close', 'args' => { 'from' => 'yesterday.from', 'to' => 'yesterday.to' } }]], [added.question_id, added.checks]
    assert_equal 'What did the register take in cash yesterday?', items('finance').last.question
    assert_match(/\Afinance-edited-[0-9a-f]{6}\z/, Current.set(tenant: @admin.tenant) { TeamChat::Battery.run_set_name('finance') })

    patch team_chat_question_path('f22', set: 'finance'), params: { question: 'What did the store take today, per register?', cadence: 'daily', checks: 'daily_close' }
    assert_equal 'What did the store take today, per register?', items('finance').find { |item| item.id == 'f22' }.question
    delete team_chat_question_path('f22', set: 'finance')
    assert_equal 'How much money has the store made today?', items('finance').find { |item| item.id == 'f22' }.question

    post remove_team_chat_question_path('f21', set: 'finance')
    assert_nil(items('finance').find { |item| item.id == 'f21' })
    get team_chat_questions_path(set: 'finance')
    assert_select 'section[aria-label="Removed built-in questions"] code', 'f21'
    delete team_chat_question_path('f21', set: 'finance')
    assert(items('finance').any? { |item| item.id == 'f21' })
    delete team_chat_question_path('w1', set: 'finance')
    assert_empty edits
    assert_equal 'finance', Current.set(tenant: @admin.tenant) { TeamChat::Battery.run_set_name('finance') }, 'no edits: the built-in set again'
  end

  test 'checks must be read-only Rupert tools' do
    post team_chat_questions_path(set: 'default'), params: { question: 'Make a task', cadence: 'daily', checks: 'create_task' }
    assert_empty edits
    assert_match(/not a read-only Rupert tool/, flash[:alert])
  end

  test 'a run is queued in the background for a running bot only' do
    assert_enqueued_with(job: TeamChat::BatteryJob, args: [@admin.id, 'finance', 'rupert']) do
      post run_team_chat_questions_path(set: 'finance'), params: { agent: 'rupert' }
    end
    assert_no_enqueued_jobs(only: TeamChat::BatteryJob) { post run_team_chat_questions_path(set: 'finance'), params: { agent: 'liquid' } }
  end

  test 'only people who can use team chat open it' do
    delete logout_path
    reader = User.create!(tenant: @admin.tenant, email: 'questions-reader@example.com', name: 'Reader', role: 'reader', password: 'password123')
    post login_path, params: { email: reader.email, password: 'password123' }
    get team_chat_questions_path
    assert_response :forbidden
  end
end
