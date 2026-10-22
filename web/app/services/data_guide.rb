# frozen_string_literal: true

# How Rupert's business data is stored and which tools answer which questions
# (config/team_chat/data_guide.yml). A question's keywords pick its topics:
# team chat puts those cards in a bot's instructions and gives local bots only
# those topics' tools; the data_guide MCP tool and rupert://guide/data serve the
# same cards to outside assistants.
module DataGuide
  CONFIG = Rails.root.join('config/team_chat/data_guide.yml')
  MAX_TOPICS = 3

  Topic = Struct.new(:key, :title, :keywords, :tools, :card, keyword_init: true) do
    def pattern = @pattern ||= /(?<![\p{L}\p{N}])(?:#{keywords.sort_by { |word| -word.length }.map { |word| Regexp.escape(word) }.join('|')})(?![\p{L}\p{N}])/i

    def markdown = "### #{title}\nTools: #{tools.map { |tool| "`#{tool}`" }.join(', ')}\n#{card}"
  end

  module_function

  def topics
    @topics = nil if Rails.env.development?
    @topics ||= YAML.safe_load_file(CONFIG).fetch('topics').map do |row|
      Topic.new(key: row.fetch('key'), title: row.fetch('title'), keywords: Array(row['keywords']).map(&:to_s),
        tools: Array(row['tools']).map(&:to_s), card: row.fetch('card').to_s.squish)
    end.freeze
  end

  def find(key) = topics.find { |topic| topic.key == key.to_s }

  # The topics a question is about, most keyword hits first (at most MAX_TOPICS).
  def match(text)
    text = text.to_s
    topics.filter_map { |topic| [topic, text.scan(topic.pattern).size] if text.match?(topic.pattern) }
          .sort_by { |topic, hits| [-hits, topics.index(topic)] }.first(MAX_TOPICS).map(&:first)
  end

  # Tool names for these topics, in order, without repeats.
  def tools_for(topics) = Array(topics).flat_map(&:tools).uniq

  def markdown(list = topics)
    ["# How Rupert's data is stored, and which tool answers what", '',
     'Money is integer cents unless a field says otherwise (team chat bots also get *_dollars). Sources and currencies are never added together. Unknown is not zero.',
     '', *Array(list).map(&:markdown)].join("\n\n")
  end
end
