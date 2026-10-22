# frozen_string_literal: true

module TeamChat
  # Posts a person's message (text, files and @mentions) and, when the room
  # calls for it, starts @rupert's reply: a pending assistant message the page
  # shows at once, filled in by TeamChat::ReplyJob.
  class Post
    class Invalid < StandardError; end
    class Limited < StandardError; end

    REPLIES_PER_WINDOW = 30
    WINDOW = 10.minutes

    Result = Struct.new(:message, :reply, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(room:, user:, body:, parent_id: nil, files: [], mention_ids: [])
      @room = room
      @user = user
      @body = body.to_s.scrub('').gsub(AskRupert::Redactor::CONTROL, '').strip
      @parent_id = parent_id.presence
      @files = Array(files).compact_blank
      @mention_ids = Array(mention_ids).map(&:to_i).uniq
    end

    def call
      attachments = build_attachments
      raise Invalid, 'Write a message or add a file first.' if @body.blank? && attachments.empty?
      raise Invalid, "Keep it under #{Message::BODY_MAX} characters." if @body.length > Message::BODY_MAX

      people = mentioned_people
      message = nil
      reply = nil
      Message.transaction do
        message = @room.messages.new(user: @user, author_kind: 'person', body: @body, parent_id: @parent_id, mentions: people.map(&:id).presence)
        attachments.each { |attachment| attachment.room = @room }
        message.attachments = attachments
        message.save!
        people.each { |person| @room.membership_for(person) }
        reply = start_reply(message) if answer?(message)
      end
      @room.membership_for(@user).mark_read!(message.id)
      ReplyJob.perform_later(reply.id) if reply
      Result.new(message: message, reply: reply)
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, e.record.errors.full_messages.to_sentence
    end

    # Everyone who can be @mentioned in team chat: the people allowed to use it.
    def self.mentionable
      User.where(tenant_id: Current.tenant_id, active: true).order(:name).select { |user| TeamChat.allowed?(user) }
    end

    private

    def build_attachments
      raise Invalid, "Attach at most #{Attachment::MAX_PER_MESSAGE} files to one message." if @files.size > Attachment::MAX_PER_MESSAGE

      @files.map do |file|
        attachment = Attachment.from_upload(file)
        raise Invalid, attachment if attachment.is_a?(String)

        attachment
      end
    end

    # Only people who can use team chat, and only when their name is in the text.
    def mentioned_people
      return [] if @mention_ids.empty?

      User.where(id: @mention_ids, tenant_id: @room.tenant_id, active: true).select do |person|
        TeamChat.allowed?(person) && @body.include?("@#{person.display_name}")
      end
    end

    def answer?(message)
      case @room.assistant_mode
      when 'all' then true
      when 'mentions' then message.mentions_rupert?
      else false
      end
    end

    def start_reply(message)
      raise Limited, 'Rupert has answered a lot of your messages in the last few minutes. Wait a moment and ask again.' if limited?

      @room.messages.create!(author_kind: 'assistant', status: 'pending', activity: 'Thinking', parent_id: message.parent_id,
        meta: { 'asked_by' => @user.id, 'trigger_id' => message.id })
    end

    def limited?
      Message.unscoped.where(tenant_id: @room.tenant_id, author_kind: 'assistant', created_at: WINDOW.ago..)
             .where('meta LIKE ?', "%\"asked_by\":#{@user.id},%").count >= REPLIES_PER_WINDOW
    end
  end
end
