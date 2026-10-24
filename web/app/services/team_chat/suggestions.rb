# frozen_string_literal: true

require 'digest'

module TeamChat
  # The suggestion bubbles above the chat box (config/team_chat/suggestions.yml): questions for this time of
  # day first, then the rest in an order that changes daily per person, so the row stays put between page loads.
  module Suggestions
    CONFIG = Rails.root.join('config/team_chat/suggestions.yml')
    COUNT = 6

    module_function

    def config = @config ||= YAML.safe_load_file(CONFIG).freeze

    # [{ label:, text: }] for this room, or none where no bot answers (a room switched off, a direct message
    # between two people).
    def for(room:, user:, now: Time.current, count: COUNT)
      return [] if room.dm? || room.assistant_mode == 'off'

      local = now.in_time_zone
      timely = Array(config[part_of_day(local)])
      timely += Array(config['monday']) if local.monday?
      timely += Array(config['month_start']) if local.day <= 5
      seed = Digest::SHA256.hexdigest("#{user.id}/#{local.to_date.iso8601}")[0, 8].to_i(16)
      rest = Array(config['anytime']).shuffle(random: Random.new(seed))
      prefix = room.channel? && room.assistant_mode == 'mentions' ? '@rupert ' : ''
      (timely + rest).map(&:to_s).map(&:strip).compact_blank.uniq.first(count).map { |question| { label: question, text: "#{prefix}#{question}" } }
    end

    FOLLOW_UPS = 4

    # The "Next:" questions after an answer: from the answer's topics, else from the tools it used, never the
    # question just asked.
    def follow_ups(topics:, tools: [], asked: nil, count: FOLLOW_UPS)
      table = config['follow_ups'] || {}
      keys = Array(topics).map(&:to_s) + Array(tools).filter_map { |tool| config.dig('tool_topics', tool.to_s) }
      asked_key = normalize(asked)
      keys.uniq.flat_map { |key| Array(table[key]) }.map(&:to_s).map(&:strip).compact_blank.uniq
          .reject { |question| normalize(question) == asked_key }.first(count)
    end

    def normalize(text) = text.to_s.downcase.gsub(/@\S+/, '').gsub(/[^a-z0-9 ]/, '').squish

    def part_of_day(time)
      return 'morning' if time.hour < 11
      return 'afternoon' if time.hour < 17

      'evening'
    end
  end
end
