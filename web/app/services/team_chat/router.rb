# frozen_string_literal: true

module TeamChat
  # Picks who answers a question that names no bot (config/team_chat/routing.yml): general questions go to a
  # fast local bot, finance to @rupert and the local bot side by side, questions that join finance with another
  # area to @rupert, and "think harder" to the careful local bot. An @mention always wins over this.
  module Router
    CONFIG = Rails.root.join('config/team_chat/routing.yml')
    THINK = /\b(?:think (?:harder|hard|deeper|deeply|carefully|it through)|take your time|dig deeper)\b/i
    # Topics that say nothing about which area a question is in.
    NEUTRAL = %w[comparison cross].freeze

    # kind: general / finance / cross / think. handles: who answers, "rupert" for @rupert.
    Route = Struct.new(:kind, :handles, keyword_init: true)

    module_function

    def config = @config ||= YAML.safe_load_file(CONFIG).freeze

    # Words that join two parts of one question ("hours worked and sales on the same days").
    JOINS = /\b(?:and|while|same days?|still|also|plus|both)\b/i

    # Keyword hits are counted per side (finance topics vs the rest). Single words are noisy ("overdue" is also a
    # books word, "today" a sales word), so a question is cross only when both sides have hits and the question
    # joins two parts, or both sides have two or more hits. Otherwise the side with more hits wins; a tie stays
    # general (local and private).
    def kind_for(text)
      text = text.to_s
      return 'think' if text.match?(THINK)

      finance_keys = Array(config['finance_topics'])
      finance = general = 0
      DataGuide.topics.each do |topic|
        next if NEUTRAL.include?(topic.key)

        hits = text.scan(topic.pattern).size
        finance_keys.include?(topic.key) ? finance += hits : general += hits
      end
      return 'cross' if finance.positive? && general.positive? && (joined?(text) || [finance, general].min >= 2)

      finance > general ? 'finance' : 'general'
    end

    # A joining word, or one of the data guide's cross-question phrases ("low on stock", "same days", ...).
    def joined?(text)
      return true if text.match?(JOINS)

      phrases = Array(DataGuide.find('cross')&.keywords) - %w[and]
      phrases.any? { |phrase| text.match?(/(?<![\p{L}\p{N}])#{Regexp.escape(phrase)}(?![\p{L}\p{N}])/i) }
    end

    def route(text)
      kind = kind_for(text)
      Route.new(kind: kind, handles: Array(config[kind]).map(&:to_s).presence || ['rupert'])
    end

    # The bots with their own room (rooms: in routing.yml) that can answer now; none without the local model server.
    def room_agents
      Array(config['rooms']).filter_map { |handle| LocalAgents.find(handle) || LocalAgents.trial(handle) }
    end

    # The bots for this question: [rupert?, local agents]. A local bot that is not available drops out;
    # if none is left, @rupert answers.
    def answerers(text)
      route = route(text)
      agents = route.handles.reject { |handle| handle == 'rupert' }.filter_map { |handle| LocalAgents.find(handle) || LocalAgents.trial(handle) }
      rupert = route.handles.include?('rupert') || agents.empty?
      [route, rupert, agents]
    end
  end
end
