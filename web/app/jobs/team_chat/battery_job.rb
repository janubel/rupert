# frozen_string_literal: true

module TeamChat
  # A test run started from Test questions: one question set asked to one bot, graded, saved to Model scores.
  # The same as `rake team_chat:battery`, in the background. One run at a time per workspace.
  class BatteryJob < ApplicationJob
    queue_as :default

    def perform(user_id, set, agent)
      user = User.find_by(id: user_id)
      return unless user&.active? && user.tenant&.status == 'active'

      Current.set(tenant: user.tenant, user: user) do
        next if BatteryRun.where(status: 'running', started_at: 3.hours.ago..).exists?

        battery = Battery.new(user: user, agent: agent, items: Battery.items(Battery.config_for(set)), set: set, out: nil)
        next if battery.already_done

        battery.run
      end
    rescue ArgumentError => e
      Rails.logger.warn("[TeamChat::BatteryJob] #{e.message.first(200)}")
    end
  end
end
