# frozen_string_literal: true

module TeamChat
  # One message in a room. People's text and the assistant's replies are
  # untrusted wherever they are shown: the page renders them as text.
  class Message < ApplicationRecord
    include TenantScoped

    AUTHOR_KINDS = %w[person assistant system].freeze
    STATUSES = %w[done pending failed].freeze
    BODY_MAX = 4_000
    MENTION = /(?<![\w@])@rupert\b/i
    # A reply still pending after this long is treated as failed (a worker died).
    # Local CPU models can take several minutes for a tool round, so this is generous.
    STALE_AFTER = 12.minutes
    COLORS = %w[#2563eb #0891b2 #7c3aed #db2777 #ea580c #16a34a #4f46e5 #0d9488].freeze

    belongs_to :room, class_name: 'TeamChat::Room'
    belongs_to :user, optional: true
    belongs_to :parent, class_name: 'TeamChat::Message', optional: true
    belongs_to :pinned_by, class_name: 'User', optional: true
    has_many :replies, class_name: 'TeamChat::Message', foreign_key: :parent_id, inverse_of: :parent, dependent: :nullify
    has_many :attachments, class_name: 'TeamChat::Attachment', dependent: :delete_all
    # The same rows without their bytes, for listing.
    has_many :attachment_infos, -> { select(:id, :message_id, :room_id, :filename, :content_type, :byte_size, :drive_status, :drive_file_id).order(:id) },
      class_name: 'TeamChat::Attachment', inverse_of: false
    has_many :reactions, class_name: 'TeamChat::Reaction', dependent: :delete_all
    has_many :ratings, class_name: 'TeamChat::Rating', dependent: :delete_all

    serialize :actions, coder: JSON
    serialize :meta, coder: JSON
    serialize :mentions, coder: JSON

    validates :author_kind, inclusion: { in: AUTHOR_KINDS }
    validates :status, inclusion: { in: STATUSES }
    validates :body, length: { maximum: BODY_MAX * 2 }
    validates :body, presence: true, if: -> { author_kind == 'person' && attachments.empty? && attachment_infos.empty? }
    validate :parent_in_same_room

    scope :visible, -> { where(deleted_at: nil) }
    scope :top_level, -> { where(parent_id: nil) }
    scope :pending, -> { where(status: 'pending') }
    scope :pinned, -> { where.not(pinned_at: nil) }

    PINS_SHOWN = 10

    after_create_commit :touch_room

    def person? = author_kind == 'person'
    def assistant? = author_kind == 'assistant'
    def system? = author_kind == 'system'
    def pending? = status == 'pending'
    def deleted? = deleted_at.present?
    def pinned? = pinned_at.present?

    def mentions_rupert? = body.to_s.match?(MENTION)

    # The local @agent that wrote this reply (LocalAgents), or nil for @rupert.
    def local_agent
      handle = meta.to_h['agent'] if assistant?
      LocalAgents.for_reply(handle)
    end

    def mention_ids = Array(mentions).map(&:to_i)

    # The message this one replies to in the room ("Replying to …"), when it quotes one.
    def quote_id = (meta.to_h['quote_id'].presence&.to_i if person?)

    def stale?
      pending? && created_at < STALE_AFTER.ago
    end

    def actions_list = Array(actions)

    def author_name
      return local_agent.name if local_agent

      case author_kind
      when 'assistant', 'system' then 'Rupert'
      else user&.display_name.presence || 'Someone'
      end
    end

    def author_initials
      return local_agent.initials if local_agent
      return 'R' unless person?

      author_name.split(/\s+/).first(2).map { |word| word[0] }.join.upcase.presence || '?'
    end

    def author_color
      return local_agent.color if local_agent
      return '#1e40af' unless person?

      COLORS[user_id.to_i % COLORS.size]
    end

    def soft_delete!
      drive_ids = attachments.where(drive_status: 'stored').pluck(:drive_file_id)
      DriveTrashJob.perform_later(tenant_id, drive_ids) if drive_ids.any?
      transaction do
        attachments.delete_all
        reactions.delete_all
        update_columns(deleted_at: Time.current, body: '', actions: nil, mentions: nil, pinned_at: nil, pinned_by_id: nil, updated_at: Time.current)
      end
    end

    # What the browser may see. Actions are server-built, never raw model output.
    # people: { user_id => name } for the mentions; quotes: { id => Message } for quoted messages.
    def as_payload(viewer:, reply_counts: {}, people: {}, quotes: {})
      {
        id: id, parent_id: parent_id, kind: author_kind, status: status, activity: (activity if pending?),
        author: { name: author_name, initials: author_initials, color: author_color, user_id: user_id, agent: local_agent&.handle, email: (user&.email if person?) },
        body: deleted? ? '' : body.to_s, deleted: deleted?, created_at: created_at.iso8601, updated_at: updated_at.iso8601,
        reply_count: reply_counts[id].to_i, mine: person? && user_id == viewer.id,
        actions: deleted? ? [] : actions_list.map { |action| action.slice('id', 'tool', 'title', 'summary', 'status', 'decided_by', 'result') },
        attachments: deleted? ? [] : attachment_infos.map { |attachment| attachment.as_payload(room) },
        mentions: mention_ids.filter_map { |id| { id: id, name: people[id] } if people[id] }, mentions_me: mention_ids.include?(viewer.id),
        reactions: reaction_summary(viewer), rating: rating_summary(viewer),
        pinned: pinned?, pinned_by: (pinned_by&.display_name if pinned?), edited: edited_at.present?,
        answer: answer_timing, compare_of: (meta.to_h['compare_of'] if assistant?),
        unverified: (Array(meta.to_h['unverified']) if assistant? && meta.to_h['unverified'].present?),
        quote: (quotes[quote_id]&.quote_payload if quote_id && !deleted?)
      }
    end

    LOCAL_ENGINES = %w[local_gateway ollama].freeze

    # How long a finished assistant reply took and which model wrote it, shown next to the post.
    def answer_timing
      return nil unless assistant? && status == 'done'

      info = meta.to_h
      return nil if info['duration_ms'].blank?

      { seconds: (info['duration_ms'].to_f / 1000).round(1), model: info['model'].presence,
        where: LOCAL_ENGINES.include?(info['engine']) ? 'local' : 'cloud' }
    end

    # Changes the text of one's own message; mentions no longer in the text are dropped.
    def edit_body!(text)
      text = text.to_s.scrub('').gsub(AskRupert::Redactor::CONTROL, '').strip
      raise ActiveRecord::RecordInvalid, self if text.blank? && attachment_infos.empty?

      kept = mention_ids.select { |id| (name = User.find_by(id: id)&.display_name) && text.include?("@#{name}") }
      update!(body: text.first(BODY_MAX), edited_at: Time.current, mentions: kept.presence)
    end

    # Pins or unpins this message as `user`. Pinning posts a short notice in the room.
    # Returns the notice when one was posted.
    def toggle_pin!(user)
      if pinned?
        update!(pinned_at: nil, pinned_by: nil)
        nil
      else
        update!(pinned_at: Time.current, pinned_by: user)
        room.messages.create!(author_kind: 'system', body: "#{user.display_name} pinned a message from #{author_name}: “#{excerpt(80)}”")
      end
    end

    # A one-line preview for pin banners and notices.
    def excerpt(length = 140)
      text = body.to_s.gsub(/\[([^\]]+)\]\([^)\s]+\)/, '\\1').gsub(/\*\*|`/, '').gsub(/\s+/, ' ').strip
      text = "📎 #{attachment_infos.map(&:filename).first(2).join(', ')}" if text.blank? && attachment_infos.any?
      text.length > length ? "#{text.first(length - 1)}…" : text
    end

    # The short "Replying to" preview shown above a reply.
    def quote_payload
      { id: id, parent_id: parent_id, author: author_name, excerpt: deleted? ? 'This message was deleted.' : excerpt(120), deleted: deleted? }
    end

    def pin_payload
      { id: id, parent_id: parent_id, author: author_name, excerpt: excerpt, pinned_by: pinned_by&.display_name, pinned_at: pinned_at&.iso8601 }
    end

    # Thumbs on a finished assistant reply: counts plus this viewer's choice.
    def rating_summary(viewer)
      return nil unless assistant? && status == 'done'

      own = ratings.find { |rating| rating.user_id == viewer.id }
      { up: ratings.count { |rating| rating.value == 1 }, down: ratings.count { |rating| rating.value == -1 },
        mine: { 1 => 'up', -1 => 'down' }[own&.value], my_reason: own&.reason }
    end

    def reaction_summary(viewer)
      reactions.group_by(&:emoji).map do |emoji, rows|
        { emoji: emoji, count: rows.size, mine: rows.any? { |row| row.user_id == viewer.id }, names: rows.filter_map { |row| row.user&.display_name }.first(10) }
      end
    end

    private

    def parent_in_same_room
      return if parent_id.blank?

      errors.add(:parent_id, 'must be in the same room') unless parent && parent.room_id == room_id && parent.parent_id.nil?
    end

    def touch_room
      room.update_columns(last_message_at: created_at, updated_at: Time.current)
    end
  end
end
