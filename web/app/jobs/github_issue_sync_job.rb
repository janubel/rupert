# frozen_string_literal: true

# Every 30 minutes: posts any recent report that is not on GitHub yet (a failed
# or skipped post), then closes reports whose GitHub issue was closed.
class GithubIssueSyncJob < ApplicationJob
  queue_as :default

  def perform
    return unless GithubIssues.configured?

    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) do
        AgentFeedback.where(github_issue_number: nil, created_at: 7.days.ago..).find_each do |feedback|
          GithubIssues.post_report!(feedback)
        rescue GithubIssues::Error => e
          logger.warn("#{self.class}: report #{feedback.id} not posted: #{e.message}")
        end
        GithubIssues.sync!
      end
    rescue StandardError => e
      logger.error("#{self.class}: sync failed for tenant #{tenant.id}: #{e.class}")
    end
  end
end
