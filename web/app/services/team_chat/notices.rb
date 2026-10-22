# frozen_string_literal: true

module TeamChat
  # Rupert's own automatic posts (sync results, sales announcements, the
  # operations brief, fulfillment alerts, count submissions) go into the
  # #announcements room as notices. Anyone in the room can ask @rupert about them.
  #
  # Nothing is posted until team chat has been opened once in the workspace (so
  # a fresh install stays quiet), and posting never raises.
  module Notices
    ROOM_SLUG = 'announcements'
    TOPIC = 'Rupert’s automatic notices: syncs, sales, alerts and the daily brief. Mention @rupert to ask about one.'

    module_function

    # Team chat is in use in this workspace.
    def configured?
      Current.tenant_id.present? && Room.channels.exists?
    end

    # Posts a notice. Returns [true, 'posted'] or [false, reason], like the old Buzz notify.
    def notify(text, room: nil)
      return [false, 'team chat is not set up yet'] unless configured?

      body = text.to_s.scrub('').strip.first(Message::BODY_MAX)
      return [false, 'empty notice'] if body.blank?

      target = room_for(room)
      target.messages.create!(author_kind: 'system', body: body)
      [true, 'posted']
    rescue StandardError => e
      Rails.logger.warn("[TeamChat::Notices] #{e.class}: #{e.message.to_s.first(160)}")
      [false, e.message.to_s.first(160)]
    end

    def room_for(slug)
      found = Room.open.channels.find_by(slug: slug.to_s) if slug.present?
      found || Room.open.channels.find_by(slug: ROOM_SLUG) ||
        Room.create!(name: ROOM_SLUG, slug: ROOM_SLUG, topic: TOPIC, assistant_mode: 'mentions')
    end
  end
end
