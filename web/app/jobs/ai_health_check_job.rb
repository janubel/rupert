# frozen_string_literal: true

# Periodic (config/recurring.yml) and on-demand check of the opencode
# integration. Spends no tokens; see OpencodeHealth.
class AiHealthCheckJob < ApplicationJob
  queue_as :default

  def perform(trigger = 'scheduled')
    OpencodeHealth.check!(trigger: trigger)
  end
end
