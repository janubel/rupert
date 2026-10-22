# frozen_string_literal: true

# Channels in the Buzz workspace that the Rupert agent can see. Buzz stores
# NIP-29 group metadata as kind 39000 events and membership as kind 39002.
# Memberships are the source of truth (a channel can exist before its metadata
# arrives), and the list is cached briefly so the chat page does not pay for a
# relay round trip on every poll.
class BuzzChannels
  Channel = Struct.new(:id, :name, :about, :members, :pubkeys, keyword_init: true)

  CACHE_TTL = 5.minutes

  class << self
    def list
      return [] unless BuzzChat.ready?

      cached = Rails.cache.read(cache_key)
      return cached if cached

      channels = fetch
      # A relay hiccup must not hide every channel for five minutes.
      Rails.cache.write(cache_key, channels, expires_in: CACHE_TTL) if channels.any?
      channels
    rescue StandardError => e
      Rails.logger.warn("[BuzzChannels] #{e.class}: #{e.message.to_s[0, 160]}")
      []
    end

    # Explicit channel selection may arrive before this process has a cached
    # channel list (for example a bookmarked ?channel= URL), so fall back to one
    # relay read. If the cache was warm but stale (a channel was just added),
    # refresh once so a newly visible channel can be opened without a restart.
    def find(id)
      return nil if id.blank?

      requested = id.to_s
      cached = list_cached
      found = (cached || list).find { |channel| channel.id == requested }
      return found if found || cached.nil?

      refresh!.find { |channel| channel.id == requested }
    end

    def refresh!
      Rails.cache.delete(cache_key)
      list
    end

    def default
      id = BuzzAgent.channel_id
      list_cached&.find { |channel| channel.id == id } ||
        Channel.new(id: id, name: 'rupert', about: 'Team chat', members: 0, pubkeys: [])
    end

    def fallback
      Channel.new(id: BuzzAgent.channel_id, name: 'rupert', about: 'Team chat', members: 0, pubkeys: [])
    end

    private

    def list_cached = Rails.cache.read(cache_key)

    def cache_key = "buzz_channels/#{Current.tenant_id}"

    def fetch
      events = BuzzRelayClient.query([{ kinds: [39_000, 39_002], limit: 500 }])
      metas = events.select { |event| event['kind'] == 39_000 && !archived?(event) }
      memberships = events.select { |event| event['kind'] == 39_002 }
      people = member_lists(memberships)
      by_id = metas.index_by { |event| tag(event, 'd') }

      (by_id.keys + memberships.map { |event| tag(event, 'd') }).compact.uniq.filter_map do |id|
        meta = by_id[id]
        next if meta && archived?(meta)

        Channel.new(
          id: id,
          name: (meta && tag(meta, 'name')).presence || 'channel',
          about: (meta && tag(meta, 'about')).to_s,
          members: people[id].to_a.size,
          pubkeys: people[id].to_a
        )
      end.sort_by { |channel| channel.name.downcase }
    end

    def archived?(event)
      Array(event['tags']).any? { |entry| entry.is_a?(Array) && entry[0] == 'archived' && entry[1] == 'true' }
    end

    def member_lists(events)
      events.each_with_object({}) do |event, lists|
        id = tag(event, 'd')
        next if id.blank?

        lists[id] ||= []
        lists[id] |= Array(event['tags']).filter_map do |entry|
          entry[1].to_s if entry.is_a?(Array) && entry[0] == 'p' && entry[1].to_s.match?(/\A\h{64}\z/)
        end
      end
    end

    def tag(event, name)
      Array(event['tags']).find { |entry| entry.is_a?(Array) && entry[0] == name }&.at(1)
    end
  end
end
