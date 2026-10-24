# frozen_string_literal: true

# What is left before the next release: the open GitHub issues on the release milestone (GithubIssues.release_tracker).
# Read-only; the issues are worked and closed on GitHub.
class ReleaseTrackerController < AuthenticatedController
  def show
    authorize(:module, :settings_read?)
    @tracker = GithubIssues.release_tracker(refresh: params[:refresh].present?)
  end
end
