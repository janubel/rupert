# frozen_string_literal: true

module TeamChat
  # Optional check-and-fix passes after a local bot answers (RUPERT_VERIFY=1, or a comma list of bot handles).
  #
  # Built on what the research says works for small models (see docs/ops/team-chat.md, "Checking answers"):
  # - the checker sees only the answer's sentences and the tool data, never the bot's reasoning, and must quote
  #   the evidence; Rupert then confirms the quote really is in the data (an invented quote is not support);
  # - it never asks "are you sure?" (models flip right answers when challenged);
  # - the fix pass runs only for sentences that failed (a figure not in the data, or the checker found the data
  #   says otherwise / does not say it), is told exactly which sentences, and its answer is kept only if it does
  #   not lose figures that were right and does not add new unchecked ones. One round, no loops.
  class Verify
    MAX_CLAIMS = 12
    MAX_EVIDENCE_CHARS = 12_000
    VERDICTS = %w[supported contradicted not_found no_fact].freeze
    FIGURE = /\d/

    Claim = Struct.new(:id, :text, :verdict, :quote, :reason, keyword_init: true) do
      def failed? = reason.present?
    end
    Outcome = Struct.new(:text, :claims, :fixed, :kept, :draft, :ms, keyword_init: true) do
      def failed = claims.select(&:failed?)

      def meta
        { 'claims' => claims.size, 'supported' => claims.count { |claim| claim.verdict == 'supported' && !claim.failed? },
          'failed' => failed.map { |claim| { 'text' => claim.text.first(200), 'reason' => claim.reason } },
          'fixed' => fixed, 'kept' => kept, 'ms' => ms, 'draft' => (draft.first(4000) if kept == 'fixed') }.compact
      end
    end

    CHECK_PROMPT = <<~PROMPT
      You check sentences from a business assistant's answer against DATA returned by Rupert's tools.
      For each numbered sentence, look in the DATA for what it states:
      - supported: the DATA says this. Copy the words that say it into evidence_quote.
      - contradicted: the DATA says something different. Copy the words that say it into evidence_quote.
      - not_found: the DATA does not mention it. Leave evidence_quote empty.
      - no_fact: the sentence states no fact (a greeting, an offer to help, a link to a page, "I could not check X").
      Copy evidence_quote exactly from the DATA, at most 25 words. Judge only against the DATA, not style or wording.
    PROMPT

    FIX_PROMPT = <<~PROMPT
      You correct a business assistant's answer using DATA from Rupert's tools.
      Change ONLY the sentences listed under WRONG. For each one, write it again with the figure or fact the DATA gives;
      if the DATA has nothing for it, remove the sentence. Copy every other sentence exactly as it is.
      Do not add caveats, apologies, new facts or calculations. Keep links and formatting.
      Reply with the whole corrected answer and nothing else.
    PROMPT

    SCHEMA = {
      type: 'object',
      properties: {
        checks: {
          type: 'array',
          items: {
            type: 'object',
            properties: { id: { type: 'integer' }, evidence_quote: { type: 'string' }, verdict: { type: 'string', enum: VERDICTS } },
            required: %w[id evidence_quote verdict], additionalProperties: false
          }
        }
      },
      required: ['checks'], additionalProperties: false
    }.freeze

    def self.enabled_for?(agent)
      setting = ENV['RUPERT_VERIFY'].to_s.strip
      return false if agent.nil? || setting.empty? || setting == '0'

      %w[1 all true].include?(setting) || setting.split(',').map(&:strip).include?(agent.handle)
    end

    # config: the bot's ModelConfig. question: what was asked. evidence: tool results. draft: the bot's answer.
    # chat_factory: builds a RubyLLM chat (tests pass their own).
    def initialize(config:, question:, evidence:, draft:, session: 'verify', chat_factory: nil)
      @config = config
      @question = question.to_s
      @evidence = Array(evidence).compact.join("\n\n").first(MAX_EVIDENCE_CHARS)
      @draft = draft.to_s
      @session = session
      @chat_factory = chat_factory || ->(instructions) { @config.chat(session: @session).with_instructions(instructions).with_temperature(0) }
    end

    # Never raises: on any error the draft stands.
    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      claims = check
      text, fixed, kept = fix(claims)
      Outcome.new(text: text, claims: claims, fixed: fixed, kept: kept, draft: @draft, ms: elapsed(started))
    rescue StandardError => e
      Rails.logger.warn "[TeamChat] verify failed: #{e.class}: #{e.message.to_s.first(160)}"
      Outcome.new(text: @draft, claims: [], fixed: false, kept: 'original', draft: @draft, ms: elapsed(started))
    end

    # The answer split into sentences and list items worth checking, markdown removed.
    def self.sentences(text)
      text.to_s.split(/\n+/).flat_map { |line| line.split(/(?<=[.!?])\s+(?=[A-Z0-9*$\[(])/) }
        .map { |part| plain(part) }
        .select { |part| part.split.size >= 3 && part.match?(/[[:alpha:]]/) }
        .uniq
    end

    def self.plain(text)
      text.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\1').gsub(/[*_`#>]/, '').sub(/\A\s*(?:[-•]|\d+\.)\s+/, '').squish
    end

    private

    def check
      texts = self.class.sentences(@draft).first(MAX_CLAIMS)
      return [] if texts.empty? || @evidence.blank?

      flagged = NumberCheck.call(@draft, [@evidence, @question])
      verdicts = ask_checker(texts)
      texts.each_with_index.map do |text, index|
        found = verdicts[index + 1] || {}
        verdict = VERDICTS.include?(found['verdict']) ? found['verdict'] : 'no_fact'
        quote = found['evidence_quote'].to_s
        Claim.new(id: index + 1, text: text, verdict: verdict, quote: quote, reason: reason_for(text, verdict, quote, flagged))
      end
    end

    def ask_checker(texts)
      numbered = texts.each_with_index.map { |text, index| "#{index + 1}. #{text}" }.join("\n")
      response = @chat_factory.call(CHECK_PROMPT).with_schema(SCHEMA).ask("DATA:\n#{@evidence}\n\nSENTENCES:\n#{numbered}")
      content = response.content
      content = JSON.parse(content.to_s) unless content.is_a?(Hash)
      Array(content['checks']).grep(Hash).index_by { |row| row['id'].to_i }
    rescue JSON::ParserError
      {}
    end

    # Why a sentence failed, or nil when it passed.
    def reason_for(text, verdict, quote, flagged)
      figure = flagged.find { |value| text.include?(value) }
      return "#{figure} is not in the data" if figure
      return "the data says otherwise: \"#{quote.first(160)}\"" if verdict == 'contradicted' && quote_in_evidence?(quote)
      return nil unless text.match?(FIGURE)
      return 'the data does not say this' if verdict == 'not_found'
      return 'the quoted evidence is not in the data' if verdict == 'supported' && !quote_in_evidence?(quote)

      nil
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

    # [text, fixed?, which answer was kept]
    def fix(claims)
      wrong = claims.select(&:failed?)
      return [@draft, false, 'original'] if wrong.empty?

      list = wrong.map { |claim| "- \"#{claim.text}\" (#{claim.reason})" }.join("\n")
      prompt = "DATA:\n#{@evidence}\n\nQUESTION:\n#{@question}\n\nANSWER:\n#{@draft}\n\nWRONG:\n#{list}"
      fixed = @chat_factory.call(FIX_PROMPT).ask(prompt).content.to_s.strip
      better?(fixed, wrong) ? [fixed, true, 'fixed'] : [@draft, true, 'original']
    end

    # Keep the fix only when it still has every figure that was right and adds no unchecked one.
    def better?(fixed, wrong)
      return false if fixed.blank? || fixed.length < @draft.length * 0.3

      sources = [@evidence, @question]
      before = NumberCheck.call(@draft, sources)
      after = NumberCheck.call(fixed, sources)
      return false if (after - before).any? || after.size > before.size

      wrong_text = wrong.map(&:text).join(' ')
      right = NumberCheck.figures_in(@draft).map(&:text).uniq - before
      right.reject { |figure| wrong_text.include?(figure) }.all? { |figure| fixed.include?(figure) }
    end

    def elapsed(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
end
