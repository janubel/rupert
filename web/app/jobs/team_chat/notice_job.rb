# frozen_string_literal: true

module TeamChat
  # Posts a notice later, so a slow database write never delays a sync or a request.
  class NoticeJob < ApplicationJob
    queue_as :default

    def perform(tenant_id, text, room = nil)
      Current.tenant = Tenant.find_by(id: tenant_id)
      return unless Current.tenant

      Notices.notify(text, room: room)
    ensure
      Current.reset
    end
  end
end
