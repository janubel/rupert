# frozen_string_literal: true

# Refreshes UpdateChecker's cached comparison with GitHub.
class UpdateCheckJob < ApplicationJob
  queue_as :default

  def perform
    UpdateChecker.refresh! if UpdateChecker.enabled?
  end
end
