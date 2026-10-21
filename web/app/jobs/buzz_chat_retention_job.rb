# frozen_string_literal: true

# Deletes Team chat copies past the retention window (the relay keeps the history).
class BuzzChatRetentionJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.find_each do |tenant|
      Current.tenant = tenant
      BuzzChat.purge!
    end
  ensure
    Current.reset
  end
end
