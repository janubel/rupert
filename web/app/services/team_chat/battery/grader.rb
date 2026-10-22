# frozen_string_literal: true

module TeamChat
  class Battery
    # Grades one answer with DeepSeek (OpenCode Go): it sees the question, the bot's
    # answer, the tools the bot used and what Rupert's own tools return for the same
    # question, and replies with a 1–5 score and a one-sentence verdict.
    class Grader
      class Error < StandardError; end

      REFERENCE_CHARS = 5_000
      PROMPT = <<~TEXT
        You grade answers from a chat assistant inside Rupert, the operations app of a small retail business.
        You get the person's question, the assistant's answer, the tools it called, and REFERENCE DATA: what Rupert's own tools
        returned for the same question moments later. The reference data is the truth.

        Score the answer 1 to 5:
        5 = correct and complete: the key figures match the reference and it answers what was asked.
        4 = correct, small omissions or a little vague.
        3 = partly right: some figures right, or the right idea without the numbers that matter.
        2 = mostly wrong, or misses the point of the question.
        1 = wrong, invented numbers, links or facts, refused, or empty.
        Invented numbers or pages are serious: never above 2 when the answer states a figure the reference contradicts.
        Do not reward length. Ignore formatting.

        Reply with JSON only, no prose around it:
        {"score": <1-5>, "verdict": "<one short sentence>", "issues": ["<short issue>", ...]}
      TEXT

      def initialize(config: nil)
        @config = config || ModelConfig.new(ENV.to_h.merge('RUPERT_CHAT_PROVIDER' => 'opencode_go', 'RUPERT_CHAT_MODEL' => 'deepseek-v4.1-flash'))
      end

      def label = @config.model.to_s

      def grade(question:, answer:, reference:, tools_used:)
        raise Error, 'grader model is not configured' unless @config.native? && @config.configured?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        chat = @config.chat(session: 'rupert-battery-grader').with_instructions(PROMPT).with_temperature(0)
        text = +''
        response = chat.ask(<<~TEXT) { |chunk| text << chunk.content.to_s }
          QUESTION:
          #{question}

          ASSISTANT'S ANSWER:
          #{answer.first(4_000)}

          TOOLS IT CALLED: #{tools_used.join(', ').presence || 'none'}

          REFERENCE DATA:
          #{reference.presence || '(no reference data)'}
        TEXT
        text = response.content.to_s if text.blank? && response.respond_to?(:content)
        parse(text).merge(seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      rescue RubyLLM::Error, Faraday::Error, Net::ReadTimeout => e
        raise Error, e.message
      end

      private

      def parse(text)
        json = text.to_s[/\{.*\}/m]
        raise Error, "grader did not return JSON: #{text.to_s.first(120)}" unless json

        data = JSON.parse(json)
        score = data['score'].to_i
        raise Error, "bad score #{data['score'].inspect}" unless (1..5).cover?(score)

        { score: score, verdict: data['verdict'].to_s.squish.first(300), issues: Array(data['issues']).map { |issue| issue.to_s.squish.first(160) }.first(5) }
      rescue JSON::ParserError => e
        raise Error, "grader JSON did not parse: #{e.message.first(80)}"
      end
    end
  end
end
