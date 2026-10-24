# frozen_string_literal: true

# Warms the header's release count in the background, so no page waits on GitHub.
class ReleaseTrackerRefreshJob < ApplicationJob
  queue_as :default

  def perform
    GithubIssues.release_tracker
  end
end
