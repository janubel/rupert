# frozen_string_literal: true

require 'test_helper'

class GithubIssuesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  API = 'https://api.github.com/repos/techmore/rupert'

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Rails.cache.clear
  end

  teardown do
    %w[GITHUB_ISSUES_TOKEN GITHUB_ISSUES_MILESTONE GITHUB_ISSUES_REPO].each { |key| EnvStore.platform_set(key, nil) }
    Current.reset
  end

  def configure!
    EnvStore.platform_set('GITHUB_ISSUES_TOKEN', 'github_pat_test')
    EnvStore.platform_set('GITHUB_ISSUES_MILESTONE', 'v0.2.1')
  end

  def report(**attributes)
    AgentFeedback.create!({ kind: 'bug', source: 'app', user_id: @user.id, summary: 'Sales total wrong for jo@example.com',
      details: 'Call me at 555-123-4567. Card 4111 1111 1111 1111 failed.', related_reference: 'https://x.test/sales?date=2026-10-01&q=secret' }.merge(attributes))
  end

  test 'nothing is queued while GitHub is not configured' do
    assert_no_enqueued_jobs(only: GithubIssuePostJob) { report }
  end

  test 'a new report is queued for GitHub once configured' do
    configure!
    assert_enqueued_with(job: GithubIssuePostJob) { report }
  end

  test 'the draft keeps the words and drops personal details, names and query strings' do
    draft = GithubIssues.draft_for(report)
    assert_includes draft[:title], 'Sales total wrong'
    assert_not_includes draft[:title], 'jo@example.com'
    assert_not_includes draft[:body], '555-123-4567'
    assert_not_includes draft[:body], '4111 1111'
    assert_includes draft[:body], 'Page: `/sales`'
    assert_not_includes draft[:body], 'secret'
    assert_not_includes draft[:body], @user.display_name
  end

  test 'post_report! files the issue on the milestone once' do
    configure!
    feedback = report
    stub_request(:get, %r{#{API}/milestones}).to_return(status: 200, body: [{ title: 'v0.2.1', number: 2 }].to_json)
    post = stub_request(:post, "#{API}/issues")
      .with { |req| JSON.parse(req.body).values_at('milestone', 'labels') == [2, %w[from-rupert bug]] }
      .to_return(status: 201, body: { number: 501, html_url: 'https://github.com/techmore/rupert/issues/501', state: 'open' }.to_json)
    GithubIssues.post_report!(feedback)
    GithubIssues.post_report!(feedback.reload)
    assert_requested post, times: 1
    assert_equal 501, feedback.reload.github_issue_number
    assert_equal 'open', feedback.github_state
  end

  test 'a GitHub error leaves the report unposted' do
    configure!
    feedback = report
    stub_request(:get, %r{#{API}/milestones}).to_return(status: 200, body: '[]')
    stub_request(:post, "#{API}/issues").to_return(status: 422, body: '{}')
    assert_raises(GithubIssues::Error) { GithubIssues.post_report!(feedback) }
    assert_nil feedback.reload.github_issue_number
  end

  test 'a closed issue closes the report' do
    configure!
    done = report(github_issue_number: 7, github_state: 'open')
    dropped = report(github_issue_number: 8, github_state: 'open')
    stub_request(:get, "#{API}/issues/7").to_return(status: 200, body: { state: 'closed', state_reason: 'completed' }.to_json)
    stub_request(:get, "#{API}/issues/8").to_return(status: 200, body: { state: 'closed', state_reason: 'not_planned' }.to_json)
    assert_equal 2, GithubIssues.sync!
    assert_equal 'done', done.reload.status
    assert_equal 'wont_fix', dropped.reload.status
    assert_equal 'closed', done.github_state
  end
end
