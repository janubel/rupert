# frozen_string_literal: true

module AskRupert
  # The light abuse limit: a modest per-person rate, a daily cap and one reply in
  # flight at a time. Nothing here locks anyone out; a limited person is told
  # when to try again. Counts come from the usage ledger, so clearing a chat does
  # not reset them.
  class Limits
    Decision = Struct.new(:allowed, :reason, :retry_after, :message, keyword_init: true) do
      def allowed? = allowed
    end

    def initialize(user, config: Config.current, now: Time.current)
      @user = user
      @config = config
      @now = now
    end

    def check
      return denied(:busy, 5, 'I’m still answering your last question. Give me a moment, then ask again.') if in_flight?

      window = @config['rate_limit_window_minutes'].minutes
      recent = usage.since(@now - window).order(:created_at).pluck(:created_at)
      if recent.size >= @config['rate_limit_count']
        wait = [(recent.first + window - @now).ceil, 1].max
        return denied(:rate, wait, "You’ve asked a lot in a short time. Give it #{wait_text(wait)} and ask again.")
      end

      if usage.since(@now - 24.hours).count >= @config['daily_cap']
        wait = [(usage.since(@now - 24.hours).minimum(:created_at) + 24.hours - @now).ceil, 60].max
        return denied(:daily, wait, "That’s today’s limit for Ask Rupert. It frees up again in about #{wait_text(wait)}. You can still use Help (?) and Learn Rupert.")
      end

      Decision.new(allowed: true)
    end

    private

    def usage = Usage.accepted.for_user(@user)

    def in_flight?
      Usage.for_user(@user).where(outcome: 'pending', created_at: (@now - Message::STALE_AFTER)..).exists?
    end

    def denied(reason, retry_after, message)
      Decision.new(allowed: false, reason: reason, retry_after: retry_after, message: message)
    end

    def wait_text(seconds)
      return "#{seconds} second#{'s' unless seconds == 1}" if seconds < 90

      minutes = (seconds / 60.0).ceil
      return "#{minutes} minute#{'s' unless minutes == 1}" if minutes < 90

      hours = (minutes / 60.0).ceil
      "#{hours} hour#{'s' unless hours == 1}"
    end
  end
end
