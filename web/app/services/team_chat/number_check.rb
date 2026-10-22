# frozen_string_literal: true

module TeamChat
  # Checks a bot's answer against what it was given: every dollar amount and
  # percentage in the answer must appear in its tool results (or in the
  # conversation it saw). Figures that do not are returned so the page can flag
  # them: a model that adds, converts or invents a number gets caught whichever
  # model it is.
  #
  # Cents count as dollars too (21483 in a tool result matches $214.83), and a
  # whole-dollar figure may round a known amount ($215 for 214.83).
  module NumberCheck
    MONEY = /(?<![\w.])(?<neg>-|−)?\$\s?(?<amount>\d[\d,]*(?:\.\d+)?)(?:\s?(?<scale>k|K|thousand|million|M)\b)?|(?<![\w.$])(?<amount2>\d[\d,]*\.\d{2})\s?(?:USD|dollars)\b/
    PERCENT = /(?<![\w.])(?<value>\d[\d,]*(?:\.\d+)?)\s?%/
    NUMBER = /\d[\d,]*(?:\.\d+)?/
    SCALES = { 'k' => 1_000, 'K' => 1_000, 'thousand' => 1_000, 'million' => 1_000_000, 'M' => 1_000_000 }.freeze
    MAX_FLAGS = 8

    Figure = Struct.new(:text, :value, :kind, :decimals, :at, keyword_init: true)

    module_function

    # answer: the reply text. sources: texts the bot was given. Returns the figures not found, as written.
    def call(answer, sources)
      figures = figures_in(answer.to_s)
      return [] if figures.empty?

      known = known_values(Array(sources).compact.join("\n"))
      figures.reject { |figure| found?(figure, known) }.map(&:text).uniq.first(MAX_FLAGS)
    end

    def figures_in(text)
      money = text.to_enum(:scan, MONEY).map do
        match = Regexp.last_match
        raw = match[:amount] || match[:amount2]
        value = raw.delete(',').to_f * SCALES.fetch(match[:scale].to_s, 1)
        Figure.new(text: match[0].strip, value: value, kind: :money, at: match.begin(0), decimals: raw[/\.(\d+)\z/, 1].to_s.length - Math.log10(SCALES.fetch(match[:scale].to_s, 1)).round)
      end
      percents = text.to_enum(:scan, PERCENT).map do
        match = Regexp.last_match
        Figure.new(text: match[0].strip, value: match[:value].delete(',').to_f, kind: :percent, at: match.begin(0), decimals: match[:value][/\.(\d+)\z/, 1].to_s.length)
      end
      (money + percents).reject { |figure| figure.value.zero? }.sort_by(&:at)
    end

    # Every number in the sources, plus each integer read as cents.
    def known_values(text)
      text.scan(NUMBER).each_with_object([]) do |raw, values|
        number = raw.delete(',').to_f
        values << number
        values << number / 100 if raw.match?(/\A[\d,]+\z/)
      end.uniq
    end

    def found?(figure, known)
      tolerance = if figure.decimals.positive? then 0.0051
                  elsif figure.decimals.zero? then 0.5
                  else (10**-figure.decimals) / 2.0 # $28k matches 27,500–28,500
                  end
      tolerance = 0.051 if figure.kind == :percent && figure.decimals.positive?
      known.any? { |value| (value.abs - figure.value).abs <= tolerance }
    end
  end
end
