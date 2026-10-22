# frozen_string_literal: true

# Who is typing in Buzz right now, for the WebUI client: people in the Buzz
# apps or in Rupert, and the @rupert agent while it works on an answer (the
# agent harness sends the same typing events). Typing indicators are ephemeral
# kind 20002 events that the relay passes to live subscribers and never stores,
# so a background thread in this web process keeps one subscription open while
# someone has the page open, and stops a minute after the last poll.
#
# Each indicator lasts TTL seconds (the Buzz apps re-send every 3 seconds while
# typing) and is cleared as soon as that person's message arrives. State lives
# in this process only; the web server runs one process (config/puma.rb).
class BuzzTyping
  TTL = 8
  IDLE_STOP = 60
  RETRY_AFTER = 5
  TYPING_KIND = BuzzChat::TYPING_KIND

  @mutex = Mutex.new
  @entries = {} # [tenant_id, channel] => { pubkey => { expires_at:, thread: } }
  @watchers = {} # tenant_id => { thread:, wanted_at:, channels: }

  class << self
    # Called on every poll: (re)starts the subscription for this tenant's
    # channels, and again whenever the channels or the relay address change.
    def watch!(tenant_id, channels, relay: BuzzAgent.relay_url)
      channels = Array(channels).map(&:to_s).select { |id| id.match?(/\A[0-9a-f-]{36}\z/) }.uniq.sort
      return if channels.empty?

      @mutex.synchronize do
        watcher = @watchers[tenant_id]
        if watcher && watcher[:thread]&.alive? && watcher[:channels] == channels && watcher[:relay] == relay
          watcher[:wanted_at] = monotonic
        else
          watcher&.dig(:thread)&.kill
          @watchers[tenant_id] = { channels: channels, relay: relay, wanted_at: monotonic, thread: start(tenant_id, channels) }
        end
      end
    end

    # [{ pubkey:, thread: }] typing in the channel now, oldest first.
    def current(tenant_id, channel)
      now = Time.now.to_f
      @mutex.synchronize do
        entries = @entries[[tenant_id, channel.to_s]] || {}
        entries.delete_if { |_, entry| entry[:expires_at] <= now }
        entries.sort_by { |_, entry| entry[:since] }.map { |pubkey, entry| { pubkey: pubkey, thread: entry[:thread] } }
      end
    end

    # One relay event (typing or a message) seen by the subscription.
    def record(tenant_id, event)
      channel = Array(event['tags']).find { |tag| tag[0] == 'h' }&.dig(1).to_s
      pubkey = event['pubkey'].to_s
      return if channel.empty? || !pubkey.match?(/\A\h{64}\z/)

      key = [tenant_id, channel]
      @mutex.synchronize do
        entries = (@entries[key] ||= {})
        if event['kind'].to_i == TYPING_KIND
          expires_at = event['created_at'].to_i + TTL
          return if expires_at <= Time.now.to_f

          thread = Array(event['tags']).find { |tag| tag[0] == 'e' && tag[3] == 'reply' }&.dig(1)
          since = entries.dig(pubkey, :since) || Time.now.to_f
          entries[pubkey] = { expires_at: expires_at, thread: thread, since: since }
        else
          entries.delete(pubkey)
        end
      end
    end

    def reset!
      @mutex.synchronize do
        @watchers.each_value { |watcher| watcher[:thread]&.kill }
        @watchers = {}
        @entries = {}
      end
    end

    private

    def start(tenant_id, channels)
      Thread.new do
        Thread.current.name = 'buzz-typing'
        Thread.current.report_on_exception = false
        Rails.application.executor.wrap { run(tenant_id, channels) }
      end
    end

    def run(tenant_id, channels)
      Current.tenant = Tenant.find_by(id: tenant_id)
      return unless Current.tenant && BuzzAgent.configured?

      loop do
        break if idle?(tenant_id)

        begin
          filters = [{ kinds: [TYPING_KIND], '#h': channels },
                     { kinds: BuzzChat::KINDS, '#h': channels, since: Time.now.to_i }]
          BuzzRelayClient.stream(filters, stop: -> { idle?(tenant_id) }) { |event| record(tenant_id, event) }
        rescue BuzzRelayClient::Error => e
          Rails.logger.info("[BuzzTyping] #{e.message.to_s[0, 120]}; retrying")
          sleep RETRY_AFTER
        end
      end
    ensure
      Current.reset
    end

    def idle?(tenant_id)
      wanted_at = @mutex.synchronize { @watchers.dig(tenant_id, :wanted_at) }
      wanted_at.nil? || monotonic - wanted_at > IDLE_STOP
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
