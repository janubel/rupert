# frozen_string_literal: true

# Deletes Ask Rupert chats past each workspace's retention window, and usage
# counters older than the longest window anything reads.
class AskRupertRetentionJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.find_each do |tenant|
      Current.tenant = tenant
      AskRupert::Retention.purge!
    end
  ensure
    Current.reset
  end
end
