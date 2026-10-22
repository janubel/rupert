# frozen_string_literal: true

require 'digest'
require 'json'

# The people in a Buzz channel, as a short roster for the mirror header. Buzz
# membership is a list of public keys; names come from kind 0 profiles when
# they exist, then from the workspace's BUZZ_MEMBER_NAMES mapping, then a
# neutral label. Avatars are initials and a stable colour, so the mirror still
# shows a useful face before everyone has published a profile.
class BuzzMembers
  Member = Struct.new(:pubkey, :name, :initials, :color, keyword_init: true)

  MAX = 6

  class << self
    def roster(channel)
      keys = Array(channel&.pubkeys).map(&:to_s).select { |key| key.match?(/\A\h{64}\z/) }.uniq
      keys -= [agent_pubkey].compact
      profiles = BuzzProfile.where(pubkey: keys).index_by(&:pubkey)
      configured = configured_names

      keys.first(MAX).map do |pubkey|
        name = profiles[pubkey]&.label.presence || configured[pubkey].presence || 'Teammate'
        Member.new(pubkey: pubkey, name: name, initials: initials(name), color: color(pubkey))
      end
    end

    def extra_count(channel)
      keys = Array(channel&.pubkeys).map(&:to_s).select { |key| key.match?(/\A\h{64}\z/) }.uniq
      keys -= [agent_pubkey].compact
      [keys.size - MAX, 0].max
    end

    def agent_pubkey
      BuzzAgent.public_key_hex
    rescue StandardError
      nil
    end

    def initials(name)
      words = name.to_s.strip.split(/\s+/).reject(&:empty?)
      (words.first(2).map { |word| word[0] }.join.presence || '?').upcase
    end

    def color(pubkey)
      hue = Digest::SHA256.hexdigest(pubkey.to_s).first(4).to_i(16) % 360
      "hsl(#{hue} 38% 48%)"
    end

    def configured_names
      raw = EnvStore.fetch('BUZZ_MEMBER_NAMES', '{}').to_s
      data = JSON.parse(raw)
      data.is_a?(Hash) ? data.transform_keys(&:to_s).transform_values(&:to_s) : {}
    rescue JSON::ParserError
      {}
    end
  end
end
