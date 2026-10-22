# frozen_string_literal: true

module TeamChat
  # Optional check-and-fix passes after a local bot answers (RUPERT_VERIFY=1, or a comma list of bot handles).
  #
  # Built on what the research says works for small models (docs/ops/team-chat.md, "Checking answers"):
  # - Rupert itself checks every number in the answer against the tool data (dates and years aside), the same way
  #   NumberCheck checks $ and %; that is the strongest signal and costs nothing;
  # - the model checker sees only the answer's sentences and the tool data, never the conversation or the bot's
  #   reasoning, and must quote the evidence for a contradiction; Rupert confirms the quote is really in the data;
  # - it never asks "are you sure?" (challenged models flip right answers);
  # - the fix pass returns only a replacement (or removal) for each failed sentence and Rupert splices it in, so every
  #   other sentence stays word for word; a replacement with a number the data does not have is not used.
  # One round, no loops. Both passes share the system prompt and the DATA block so the model server reuses them.
  class Verify
    MAX_CLAIMS = 10
    MAX_EVIDENCE_CHARS = 12_000
    VERDICTS = %w[supported contradicted not_found no_fact].freeze

    SYSTEM = <<~PROMPT
      You check and correct a business assistant's answer against DATA returned by Rupert's tools.
      Judge only against the DATA, never against what you think is likely. Do not judge style or wording.
      The user message gives the DATA first, then a TASK with its own instructions. Answer in the JSON asked for.
    PROMPT

    CHECK_TASK = <<~TASK
      TASK: CHECK. For each numbered sentence, say what the DATA says about it:
      - supported: the DATA says this;
      - contradicted: the DATA says something different (copy the words that say it into evidence_quote, at most 15 words, exactly as in the DATA);
      - not_found: the DATA does not mention it;
      - no_fact: the sentence states no fact (a greeting, an offer to help, a link to a page, a question, "I could not check X").
    TASK

    FIX_TASK = <<~TASK
      TASK: FIX. Each numbered sentence below is wrong for the reason given. For each one, give a replacement sentence
      that states what the DATA says instead, or an empty replacement to remove it if the DATA has nothing for it.
      Use only figures that appear in the DATA. No caveats, apologies, calculations or new topics.
    TASK

    CHECK_SCHEMA = {
      type: 'object',
      properties: {
        checks: { type: 'array', items: {
          type: 'object', additionalProperties: false, required: %w[id verdict evidence_quote],
          properties: { id: { type: 'integer' }, verdict: { type: 'string', enum: VERDICTS }, evidence_quote: { type: 'string' } }
        } }
      },
      required: ['checks'], additionalProperties: false
    }.freeze

    FIX_SCHEMA = {
      type: 'object',
      properties: {
        fixes: { type: 'array', items: {
          type: 'object', additionalProperties: false, required: %w[id replacement],
          properties: { id: { type: 'integer' }, replacement: { type: 'string' } }
        } }
      },
      required: ['fixes'], additionalProperties: false
    }.freeze

    MONTHS = 'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?'
    # Dates, times and years are not figures: they come from the question or the date hints as often as from data.
    DATELIKE = [
      /\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?/,
      /\b(?:#{MONTHS})\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:\s*(?:[-–]|to)\s*(?:(?:#{MONTHS})\.?\s+)?\d{1,2}(?:st|nd|rd|th)?)?(?:,?\s+\d{4})?/i,
      /\b\d{1,2}(?:st|nd|rd|th)?\s+(?:#{MONTHS})\b/i,
      /\b\d{1,2}:\d{2}(?:\s?[ap]m)?\b/i,
      /\b\d{1,2}\s?[ap]m\b/i,
      /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/,
      /\b(?:19|20)\d{2}\b/,
      /\bQ[1-4]\b/
    ].freeze
    NUMBER = /(?<![\w.])\d[\d,]*(?:\.\d+)?(?![\w])/

    # One sentence or list item of the answer: raw text as written (with markdown), its place in the answer, and plain text.
    Piece = Struct.new(:raw, :start, :plain, keyword_init: true)
    Claim = Struct.new(:id, :piece, :verdict, :quote, :reason, :replacement, keyword_init: true) do
      def text = piece.plain
      def failed? = reason.present?
    end
    Outcome = Struct.new(:text, :claims, :fixed, :kept, :draft, :ms, keyword_init: true) do
      def failed = claims.select(&:failed?)

      def meta
        { 'claims' => claims.size, 'supported' => claims.count { |claim| claim.verdict == 'supported' && !claim.failed? },
          'failed' => failed.map { |claim| { 'text' => claim.text.first(200), 'reason' => claim.reason, 'fixed' => !claim.replacement.nil? } },
          'fixed' => fixed, 'kept' => kept, 'ms' => ms, 'draft' => (draft.first(4000) if kept == 'fixed') }.compact
      end
    end

    def self.enabled_for?(agent)
      setting = ENV['RUPERT_VERIFY'].to_s.strip
      return false if agent.nil? || setting.empty? || setting == '0'

      %w[1 all true].include?(setting) || setting.split(',').map(&:strip).include?(agent.handle)
    end

    # The answer split into sentences and list items worth checking, with where each one sits in the answer.
    def self.pieces(text)
      text = text.to_s
      offset = 0
      text.split(/(\n+)/).flat_map do |line|
        line_start = offset
        offset += line.length
        next [] if line.strip.empty?

        parts = line.split(/(?<=[.!?])\s+(?=[A-Z0-9*$\[(])/)
        cursor = 0
        parts.map do |part|
          at = line.index(part, cursor)
          cursor = at + part.length
          Piece.new(raw: part, start: line_start + at, plain: plain(part))
        end
      end.select { |piece| piece.plain.split.size >= 3 && piece.plain.match?(/[[:alpha:]]/) }
    end

    def self.sentences(text) = pieces(text).map(&:plain).uniq

    def self.plain(text)
      text.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\1').gsub(/[*_`#>]/, '').sub(/\A\s*(?:[-•]|\d+\.)\s+/, '').squish
    end

    # The numbers in a text that are figures (not dates, times or years).
    def self.figures(text)
      cleaned = DATELIKE.reduce(text.to_s) { |memo, pattern| memo.gsub(pattern, ' ') }
      cleaned.scan(NUMBER).map { |raw| raw.delete(',') }.reject { |raw| raw.to_f.zero? }.uniq
    end

    # config: the bot's ModelConfig. question: what was asked. evidence: tool results. draft: the bot's answer.
    # chat_factory: builds a RubyLLM chat with the given instructions (tests pass their own).
    def initialize(config:, question:, evidence:, draft:, session: 'verify', chat_factory: nil)
      @config = config
      @question = question.to_s
      @evidence = Array(evidence).compact.join("\n\n").first(MAX_EVIDENCE_CHARS)
      @draft = draft.to_s
      @chat_factory = chat_factory || ->(instructions) { @config.chat(session: session).with_instructions(instructions).with_temperature(0) }
    end

    # Never raises: on any error the draft stands.
    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      claims = check
      text, fixed = fix(claims)
      Outcome.new(text: text, claims: claims, fixed: fixed, kept: text == @draft ? 'original' : 'fixed', draft: @draft, ms: elapsed(started))
    rescue StandardError => e
      Rails.logger.warn "[TeamChat] verify failed: #{e.class}: #{e.message.to_s.first(160)}"
      Outcome.new(text: @draft, claims: [], fixed: false, kept: 'original', draft: @draft, ms: elapsed(started))
    end

    private

    def check
      pieces = self.class.pieces(@draft).uniq(&:plain).first(MAX_CLAIMS)
      return [] if pieces.empty? || @evidence.blank?

      flagged = NumberCheck.call(@draft, sources)
      verdicts = ask(CHECK_TASK, numbered(pieces.map(&:plain)), CHECK_SCHEMA)['checks']
      by_id = Array(verdicts).grep(Hash).index_by { |row| row['id'].to_i }
      pieces.each_with_index.map do |piece, index|
        found = by_id[index + 1] || {}
        verdict = VERDICTS.include?(found['verdict']) ? found['verdict'] : 'no_fact'
        quote = found['evidence_quote'].to_s
        Claim.new(id: index + 1, piece: piece, verdict: verdict, quote: quote, reason: reason_for(piece.plain, verdict, quote, flagged))
      end
    end

    # Why a sentence failed, or nil when it passed. Numbers are checked by Rupert; the model only adds contradictions.
    def reason_for(text, verdict, quote, flagged)
      figure = flagged.find { |value| text.include?(value) }
      return "#{figure} is not in the data" if figure

      missing = unknown_figures(text)
      return "#{missing.first} is not in the data" if missing.any?
      return "the data says otherwise: \"#{quote.first(160)}\"" if verdict == 'contradicted' && quote_in_evidence?(quote)

      nil
    end

    def unknown_figures(text)
      @known ||= NumberCheck.known_values([@evidence, @question].join("\n"))
      self.class.figures(NumberCheck.figures_in(text).reduce(text) { |memo, figure| memo.sub(figure.text, ' ') })
        .reject { |raw| @known.any? { |value| (value - raw.to_f).abs < 0.0051 } }
    end

    def quote_in_evidence?(quote)
      words = normalize(quote).split
      return false if words.size < 2

      haystack = normalize(@evidence)
      return true if haystack.include?(words.join(' '))

      known = haystack.split.to_set
      words.count { |word| known.include?(word) } >= (words.size * 0.9).ceil
    end

    def normalize(text) = text.to_s.downcase.gsub(/[^[:alnum:].$%-]+/, ' ').gsub(/(?<!\d)\.|\.(?!\d)/, ' ').squish

    # [text, whether a fix was tried]. Replacements go in place of the failed sentences; everything else is untouched.
    def fix(claims)
      wrong = claims.select(&:failed?)
      return [@draft, false] if wrong.empty?

      list = wrong.each_with_index.map { |claim, index| "#{index + 1}. #{claim.piece.raw.strip} (#{claim.reason})" }
      fixes = Array(ask(FIX_TASK, "QUESTION: #{@question}\n\nWRONG SENTENCES:\n#{list.join("\n")}", FIX_SCHEMA)['fixes']).grep(Hash)
      by_id = fixes.index_by { |row| row['id'].to_i }
      text = @draft.dup
      wrong.each_with_index.sort_by { |claim, _index| -claim.piece.start }.each do |claim, index|
        row = by_id[index + 1]
        next unless row&.key?('replacement')

        replacement = row['replacement'].to_s.strip
        next unless usable?(replacement)

        claim.replacement = replacement
        text = splice(text, claim.piece, replacement)
      end
      [tidy(text), true]
    end

    # A replacement is used only when every figure in it is in the data.
    def usable?(replacement)
      return true if replacement.empty?

      NumberCheck.call(replacement, sources).empty? && unknown_figures(replacement).empty?
    end

    def splice(text, piece, replacement)
      prefix = piece.raw[/\A\s*(?:[-•]|\d+\.)\s+/].to_s
      finish = piece.start + piece.raw.length
      return text unless text[piece.start...finish] == piece.raw

      text = text[0...piece.start] + (replacement.empty? ? '' : "#{prefix}#{replacement}") + text[finish..]
      return text unless replacement.empty?

      # A removal that empties its line (or leaves only a bullet) takes the line with it.
      line_start = text.rindex("\n", [piece.start - 1, 0].max)&.then { |at| at + 1 } || 0
      line_start = 0 if piece.start.zero?
      line_end = text.index("\n", piece.start) || text.length
      return text unless text[line_start...line_end].strip.match?(/\A(?:[-•]|\d+\.)?\z/)

      text[0...line_start] + text[[line_end + 1, text.length].min..].to_s
    end

    # Spaces left where a sentence was removed in the middle of a paragraph.
    def tidy(text) = text.gsub(/(?<=\S)[ \t]{2,}/, ' ').gsub(/[ \t]+$/, '').gsub(/\n{3,}/, "\n\n").strip

    def ask(task, body, schema)
      response = @chat_factory.call(SYSTEM).with_schema(schema).ask("DATA:\n#{@evidence}\n\n#{task}\n#{body}")
      content = response.content
      content.is_a?(Hash) ? content : JSON.parse(content.to_s)
    rescue JSON::ParserError
      {}
    end

    def numbered(texts) = texts.each_with_index.map { |text, index| "#{index + 1}. #{text}" }.join("\n")
    def sources = [@evidence, @question]
    def elapsed(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
end
