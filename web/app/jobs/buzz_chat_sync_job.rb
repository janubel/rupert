# frozen_string_literal: true

# Brings one workspace's Team chat copy up to date from the Buzz relay. Started by
# the chat page's polling (at most every few seconds); never raises, because an
# unreachable relay is a state the page shows, not an error.
class BuzzChatSyncJob < ApplicationJob
  queue_as :default
  # In development jobs normally run inline; run this one in the background so the
  # page is not held up by a slow relay, as with Solid Queue in production.
  self.queue_adapter = :async if Rails.env.development?

  def perform(tenant_id)
    tenant = Tenant.find_by(id: tenant_id)
    return unless tenant

    previous = Current.tenant
    Current.tenant = tenant
    BuzzChat.sync!
  ensure
    Current.tenant = previous
  end
end
