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

    Result = Struct.new(:message, :reply, :replies, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(room:, user:, body:, parent_id: nil, files: [], mention_ids: [], quote_id: nil, prior_reply_ids: [])
      @room = room
      @user = user
      @body = body.to_s.scrub('').gsub(AskRupert::Redactor::CONTROL, '').strip
      @parent_id = parent_id.presence
      @files = Array(files).compact_blank
      @mention_ids = Array(mention_ids).map(&:to_i).uniq
      @quote_id = quote_id.presence&.to_i
      @prior_reply_ids = Array(prior_reply_ids).map(&:to_i).uniq
    end

    def call
      attachments = build_attachments
      raise Invalid, 'Write a message or add a file first.' if @body.blank? && attachments.empty?
      raise Invalid, "Keep it under #{Message::BODY_MAX} characters." if @body.length > Message::BODY_MAX

      people = mentioned_people
      quote = quoted_message
      message = nil
      replies = []
      Message.transaction do
        message = @room.messages.new(user: @user, author_kind: 'person', body: @body, parent_id: @parent_id, mentions: people.map(&:id).presence,
          meta: ({ 'quote_id' => quote.id } if quote))
        attachments.each { |attachment| attachment.room = @room }
        message.attachments = attachments
        message.save!
        # Mentioning someone pulls them into a channel, never into a private conversation.
        people.each { |person| @room.membership_for(person) } if @room.channel?
        replies = replies_for(message, quote: quote)
      end
      membership = @room.membership_for(@user)
      membership.mark_read!(message.id)
      membership.update_columns(typing_at: nil) if membership.typing_at
      replies.each { |reply| ReplyJob.perform_later(reply.id) }
      message.attachments.each { |attachment| AttachmentDriveJob.perform_later(attachment.id) } if attachments.any? && DriveStore.available?
      Result.new(message: message, reply: replies.first, replies: replies)
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, e.record.errors.full_messages.to_sentence
    end

    # Shared by a new post and an edited request; this does not post another
    # human message or enqueue before the caller's transaction has committed.
    def replies_for(message, quote: nil)
      replies = []
      if asks_everyone?
        # @all: every bot answers the same question; the page shows the answers side by side.
        replies << start_reply(message, compare: true)
        LocalAgents.all.each { |agent| replies << start_reply(message, agent: agent, compare: true) }
      elsif (owner = @room.bot_agent)
        # A bot's own room: everything goes to that bot; @mentioning another bot or @rupert brings them in too.
        replies << start_reply(message) if message.mentions_rupert?
        ([owner] + LocalAgents.mentioned(@body)).uniq(&:handle).each { |agent| replies << start_reply(message, agent: agent) }
      else
        rupert = answer?(message, quote)
        agents = LocalAgents.mentioned(@body)
        # Naming a bot asks that bot, even in a room where @rupert answers everything.
        rupert = message.mentions_rupert? if agents.any?
        # Replying to a bot's answer, without naming a bot, asks that same bot again.
        if !rupert && agents.empty? && quote&.assistant? && quote.status == 'done'
          agents = LocalAgents.all.select { |agent| agent.handle == quote.local_agent&.handle }
          rupert = agents.empty? # @rupert's own answer, or a local bot that is not running now
        end
        # Nobody named: the router picks by topic (config/team_chat/routing.yml).
        route = nil
        route, rupert, agents = Router.answerers(@body) if rupert && agents.empty? && !message.mentions_rupert?
        together = route && agents.size + (rupert ? 1 : 0) > 1
        replies << start_reply(message, compare: together, route: route&.kind) if rupert
        agents.each { |agent| replies << start_reply(message, agent: agent, compare: together, route: route&.kind) }
      end
      replies
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

    # Replying to a message quotes it; only a visible, finished message in this room.
    def quoted_message
      return nil unless @quote_id

      quote = @room.messages.visible.find_by(id: @quote_id)
      raise Invalid, 'That message is no longer here to reply to.' unless quote
      raise Invalid, 'Wait for that reply to finish first.' if quote.pending?

      quote
    end

    ALL_MENTION = /(?<![\w@])@all\b/i

    def asks_everyone? = @body.match?(ALL_MENTION)

    def answer?(message, quote = nil)
      case @room.assistant_mode
      when 'all' then message.mentions_rupert? || !to_colleague?(message, quote)
      when 'mentions' then message.mentions_rupert?
      else false
      end
    end

    # In a room where Rupert answers everything, a message meant for a colleague is left to them: one that opens by
    # addressing a person ("@Sam can you cover Saturday?") or quotes a person's message. A colleague named later
    # ("How many hours did @Sam work?") is still a question for Rupert.
    def to_colleague?(message, quote)
      (message.mention_ids.any? && @body.match?(/\A\s*@/)) || quote&.person?
    end

    # A pending assistant reply. A local @agent's reply says "Waiting for the model"
    # until the gateway has it loaded (only one model runs at a time).
    def start_reply(message, agent: nil, compare: false, route: nil)
      raise Limited, 'Rupert has answered a lot of your messages in the last few minutes. Wait a moment and ask again.' if limited?

      meta = { 'asked_by' => @user.id, 'trigger_id' => message.id }
      meta['agent'] = agent.handle if agent
      meta['compare_of'] = message.id if compare
      meta['route'] = route if route
      meta['prior_reply_ids'] = @prior_reply_ids if @prior_reply_ids.any?
      reply = @room.messages.create!(author_kind: 'assistant', status: 'pending', activity: agent ? "Loading #{agent.name}" : 'Thinking',
        parent_id: message.parent_id, meta: meta)
      Run.for_reply!(reply)
      reply
    end

    def limited?
      Message.unscoped.where(tenant_id: @room.tenant_id, author_kind: 'assistant', created_at: WINDOW.ago..)
             .where('meta LIKE ?', "%\"asked_by\":#{@user.id},%").count >= REPLIES_PER_WINDOW
    end
  end
end
