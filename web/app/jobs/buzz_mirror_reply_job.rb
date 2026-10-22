# frozen_string_literal: true

# Answers an @rupert mention posted through the WebUI's Buzz mirror/Team chat.
#
# Messages posted in the WebUI are signed by the Rupert agent key (the speaker's
# name is in the text), and the real Buzz agent deliberately ignores its own
# events. Without this job the mirror would be a one-way window: a person could
# type @rupert and never hear back. The answer is written by the same shared
# Ask Rupert brain the agent uses for rooms (navigation help only), then
# published as the agent and pulled back into the channel copy.
class BuzzMirrorReplyJob < ApplicationJob
  queue_as :default
  # In development jobs normally run inline; run this one in the background so
  # the reply arrives after the post is acknowledged, as with Solid Queue.
  self.queue_adapter = :async if Rails.env.development?

  MENTION = /@rupert\b[:,]?/i

  def perform(tenant_id, user_id, channel_id, text, event_id = nil)
    tenant = Tenant.find_by(id: tenant_id)
    user = User.find_by(id: user_id, tenant_id: tenant_id)
    return unless tenant && user
    return unless user.can?('buzz.read') && user.can?('buzz.post') && user.can?('chat.use')
    return unless channel_id.present? && AskRupert::Config.current.enabled?

    Current.tenant = tenant
    Current.user = user

    question = text.to_s.gsub(MENTION, ' ').squish
    return if question.blank?

    answer = AskRupert::HelpBrain.new(user: user, audience: :shared).answer(question)
    return unless answer&.ok && answer.text.present?

    tags = event_id.to_s.match?(/\A\h{64}\z/) ? [['e', event_id]] : []
    ok, reason = BuzzAgent.notify(answer.text.to_s.strip.first(BuzzChat::POST_MAX), channel: channel_id, tags: tags)
    unless ok
      Rails.logger.warn("[BuzzMirrorReply] publish failed: #{reason.to_s[0, 120]}")
      return
    end

    BuzzChat.sync!(channel: channel_id)
  rescue StandardError => e
    Rails.logger.warn("[BuzzMirrorReply] #{e.class}: #{e.message.to_s[0, 160]}")
  ensure
    Current.reset
  end
end
