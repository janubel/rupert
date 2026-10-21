# frozen_string_literal: true

module AskRupert
  # What the @rupert agent does with a message in Buzz, when Ask Rupert is
  # switched on for Buzz. Pure decisions, no network: the agent hands over the
  # sender's key (from the signed event) and the text, and gets back what to say,
  # or nil when this is not its business and the agent should carry on as before.
  #
  # Who is asking comes only from the key, through an active BuzzIdentity, never
  # from a name or anything typed. Linking works only in a direct message. Replies
  # are navigation help only (where_is, how_do_i); records and figures are never
  # shown in Buzz, whoever asks, because Rupert cannot know who else reads a
  # channel or how long the relay keeps it.
  class BuzzSurface
    LINK_COMMAND = /\A\s*(?:@rupert\b[:,]?\s*)?link\s+([A-Za-z0-9-]{6,14})\s*[.!]?\s*\z/i
    MENTION = /@rupert\b[:,]?/i
    LINK_ATTEMPTS = { limit: 5, window: 10.minutes }.freeze
    HINT_EVERY = 30.minutes

    # kind: :answer, :hint, :link, :limited or :silent (handled; say nothing).
    Reply = Struct.new(:text, :kind, keyword_init: true)

    # A small in-memory counter (the agent is one process). Holds keys and times, never text.
    class Throttle
      def initialize
        @hits = Hash.new { |hash, key| hash[key] = [] }
        @mutex = Mutex.new
      end

      # True and records a hit when fewer than `limit` happened in the window.
      def allow?(key, limit:, window:, now: Time.current)
        @mutex.synchronize do
          hits = @hits[key].select { |time| time > now - window }
          allowed = hits.size < limit
          hits << now if allowed
          @hits[key] = hits
          @hits.delete(key) if hits.empty?
          allowed
        end
      end
    end

    SHARED_THROTTLE = Throttle.new

    def initialize(config: Config.current, providers: nil, throttle: SHARED_THROTTLE, origin: self.class.origin)
      @config = config
      @providers = providers
      @throttle = throttle
      @origin = origin
    end

    # The public address of this Rupert, for links in Buzz replies; nil when it is not known.
    def self.origin
      value = (ENV['RUPERT_PUBLIC_ORIGIN'].presence || ENV['HOST'].presence).to_s.chomp('/')
      value if value.match?(%r{\Ahttps?://[^\s/]+\z}i)
    end

    # channel: :dm for a conversation of the agent and one person, otherwise :room (anything unknown is a room).
    # team_channel: the agent's own configured channel, where it keeps answering the way it always has (only link codes are handled here).
    def call(pubkey:, content:, channel:, addressed:, team_channel: false, context: [])
      return nil unless @config.buzz_enabled?
      return nil unless pubkey.to_s.match?(BuzzIdentity::PUBKEY)

      if (link = content.to_s.match(LINK_COMMAND))
        return handle_link(link[1], pubkey, channel)
      end
      # The team channel keeps the agent's own replies (with the operations snapshot the whole channel already sees).
      return nil if team_channel
      return nil unless addressed || channel == :dm

      identity = BuzzIdentity.lookup(pubkey)
      return unlinked(pubkey, channel) unless identity

      answer(identity, content, channel, context)
    end

    private

    def handle_link(code, pubkey, channel)
      return silent unless @throttle.allow?([:link, pubkey], **LINK_ATTEMPTS)

      if channel != :dm
        BuzzIdentity.burn(code)
        audit('buzz_link_refused', nil, "key=#{pubkey.first(8)}; reason=posted where others can read it")
        return reply("Please don’t post a link code where other people can read it. That code no longer works. Make a new one in Rupert (Buzz page) and send it to me in a direct message.", :link)
      end

      result = BuzzIdentity.claim(code: code, pubkey: pubkey)
      audit('buzz_link_claimed', result.identity&.user, "key=#{pubkey.first(8)}; result=#{result.status}")
      reply(link_message(result), :link)
    end

    def link_message(result)
      case result.status
      when :ok then "Thanks. To finish, open the Buzz page in Rupert and confirm that this key is yours: #{result.identity.fingerprint}. Nothing is linked until you do."
      when :expired then 'That code has expired. Make a new one in Rupert (Buzz page) and send it again.'
      when :taken then 'That Buzz account is already linked to a Rupert account. If that is a mistake, remove the link in Rupert first.'
      when :ineligible then 'That Rupert account cannot use Ask Rupert (it needs the Rupert Chat permission). An administrator can give it.'
      else 'That code is not valid. Make a new one in Rupert (Buzz page) and send it to me again.'
      end
    end

    # Someone whose Buzz key is not linked gets one hint, and nothing from Rupert.
    def unlinked(pubkey, channel)
      return silent unless @throttle.allow?([:hint, pubkey, channel], limit: 1, window: HINT_EVERY)

      reply('I can only help people whose Buzz account is linked to their Rupert account. In Rupert, open the Buzz page, choose Link, then send me the code here in a direct message.', :hint)
    end

    def answer(identity, content, channel, context)
      user = identity.user
      previous_user = Current.user
      Current.user = user
      decision = Limits.new(user, config: @config).check
      return reply(decision.message, :limited) unless decision.allowed?

      usage = Usage.create!(user: user, outcome: 'pending')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil
      begin
        brain = HelpBrain.new(user: user, audience: channel == :dm ? :direct_help : :shared, config: @config, providers: @providers, origin: @origin)
        result = brain.answer(content.to_s.gsub(MENTION, ' ').squish, context: context)
      ensure
        finish_usage(usage, result, started)
      end
      reply(with_notice(identity, result.text), :answer)
    ensure
      Current.user = previous_user
    end

    def finish_usage(usage, result, started)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      usage.update!(outcome: result&.ok ? 'ok' : 'error', provider: result&.provider, model: result&.model, tokens_in: result&.tokens_in.to_i,
        tokens_out: result&.tokens_out.to_i, tool_calls: result&.tool_calls.to_i, duration_ms: ms)
    rescue StandardError => e
      Rails.logger.warn "[AskRupert] could not record Buzz usage: #{e.class}"
    end

    # The first answer to a linked person says where their words go and what Buzz keeps.
    def with_notice(identity, text)
      return text if identity.disclosed_at

      identity.update_columns(disclosed_at: Time.current)
      "#{text}\n\n(#{Providers.disclosure(@config)} What you write to me here stays in Buzz, which Rupert cannot clear; I only help with where things are and how to do them, never records or figures.)"
    end

    def reply(text, kind) = Reply.new(text: text, kind: kind)
    def silent = Reply.new(text: nil, kind: :silent)

    def audit(action, user, details)
      ActivityLogger.log(action, actor: user, details: details)
    end
  end
end
