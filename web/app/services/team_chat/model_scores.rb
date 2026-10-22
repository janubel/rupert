# frozen_string_literal: true

module TeamChat
  # How each model is doing in team chat: replies, thumbs up and down, how often
  # it failed and how long people waited. Read from reply metadata and ratings.
  module ModelScores
    Row = Struct.new(:agent, :model, :engine, :replies, :failed, :up, :down, :median_seconds, :slowest_seconds, :tools_per_reply, keyword_init: true) do
      def rated = up + down
      def liked_percent = rated.zero? ? nil : ((up * 100.0) / rated).round
      def label = "@#{agent} · #{model.presence || 'unknown model'}"
    end

    REPLY_LIMIT = 5_000

    module_function

    def call(since: 30.days.ago)
      replies = Message.where(author_kind: 'assistant', created_at: since..).where.not(status: 'pending').order(id: :desc).limit(REPLY_LIMIT)
                       .pluck(:id, :status, :meta)
      ratings = Rating.where(message_id: replies.map(&:first)).group(:message_id, :value).count
      groups = Hash.new { |hash, key| hash[key] = [] }
      replies.each do |id, status, raw|
        meta = parse(raw)
        groups[[meta['agent'].presence || 'rupert', meta['model'].to_s, meta['engine'].to_s]] << [id, status, meta]
      end
      groups.map do |(agent, model, engine), rows|
        seconds = rows.filter_map { |_, status, meta| meta['duration_ms'].to_f / 1000 if status == 'done' && meta['duration_ms'] }.sort
        ids = rows.map(&:first)
        Row.new(agent: agent, model: model, engine: engine, replies: rows.size, failed: rows.count { |_, status, _| status == 'failed' },
          up: ids.sum { |id| ratings[[id, 1]].to_i }, down: ids.sum { |id| ratings[[id, -1]].to_i },
          median_seconds: seconds.empty? ? nil : seconds[seconds.size / 2].round(1), slowest_seconds: seconds.last&.round(1),
          tools_per_reply: (rows.sum { |_, _, meta| Array(meta['tools']).size }.to_f / rows.size).round(1))
      end.sort_by { |row| [-(row.liked_percent || -1), -row.replies] }
    end

    def parse(raw)
      value = raw.is_a?(String) ? JSON.parse(raw) : raw
      value.is_a?(Hash) ? value : {}
    rescue JSON::ParserError
      {}
    end
  end
end
