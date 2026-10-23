# frozen_string_literal: true

# Posts one new in-app report as a GitHub issue (GithubIssues.post_report!).
class GithubIssuePostJob < ApplicationJob
  queue_as :default
  retry_on GithubIssues::Error, wait: :polynomially_longer, attempts: 5

  def perform(feedback_id)
    feedback = AgentFeedback.unscoped.find_by(id: feedback_id)
    return unless feedback && GithubIssues.configured?

    tenant = Tenant.find_by(id: feedback.tenant_id)
    Current.set(tenant: tenant) { GithubIssues.post_report!(feedback) }
  end
end
