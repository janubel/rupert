# frozen_string_literal: true

# Channels in the Buzz workspace that the Rupert agent can see. Buzz stores
# NIP-29 group metadata as kind 39000 events and membership as kind 39002.
# The list is cached briefly so the chat page does not pay for a relay round
# trip on every poll.
class BuzzChannels
  Channel = Struct.new(:id, :name, :about, :members, keyword_init: true)

  CACHE_TTL = 5.minutes

  class << self
    def list
      return [] unless BuzzChat.ready?

      cached = Rails.cache.read(cache_key)
      return cached if cached

      channels = fetch
      Rails.cache.write(cache_key, channels, expires_in: CACHE_TTL)
      channels
    rescue StandardError => e
      Rails.logger.warn("[BuzzChannels] #{e.class}: #{e.message.to_s[0, 160]}")
      []
    end

    # Explicit channel selection may arrive before this process has a cached
    # channel list (for example a bookmarked ?channel= URL), so fall back to one
    # relay read. The default channel never does that: polling stays cheap.
    def find(id)
      return nil if id.blank?

      (list_cached || list).find { |channel| channel.id == id.to_s }
    end

    def default
      id = BuzzAgent.channel_id
      list_cached&.find { |channel| channel.id == id } || Channel.new(id: id, name: 'rupert', about: 'Team chat', members: 0)
    end

    def fallback
      Channel.new(id: BuzzAgent.channel_id, name: 'rupert', about: 'Team chat', members: 0)
    end

    private

    def list_cached = Rails.cache.read(cache_key)

    def cache_key = "buzz_channels/#{Current.tenant_id}"

    def fetch
      events = BuzzRelayClient.query([{ kinds: [39_000, 39_002], limit: 300 }])
      metas = events.select { |event| event['kind'] == 39_000 }
      counts = member_counts(events)

      metas.filter_map do |event|
        id = tag(event, 'd')
        next if id.blank?

        Channel.new(
          id: id,
          name: tag(event, 'name').presence || 'channel',
          about: tag(event, 'about').to_s,
          members: counts[id].to_i
        )
      end.uniq(&:id).sort_by { |channel| channel.name.downcase }
    end

    def member_counts(events)
      events.select { |event| event['kind'] == 39_002 }.each_with_object({}) do |event, counts|
        id = tag(event, 'd')
        next if id.blank?

        counts[id] = Array(event['tags']).count do |entry|
          entry.is_a?(Array) && entry[0] == 'p' && entry[1].to_s.match?(/\A\h{64}\z/)
        end
      end
    end

    def tag(event, name)
      Array(event['tags']).find { |entry| entry.is_a?(Array) && entry[0] == name }&.at(1)
    end
  end
end
