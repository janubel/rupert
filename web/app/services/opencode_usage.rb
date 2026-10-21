# frozen_string_literal: true

require 'json'

# Reads one `opencode run --format json` stream: token totals from the
# step-finish events, and the kind of failure when the run did not produce a
# reply. Only numbers and classifications leave this class — never the text of
# the prompt, the reply, or an error message.
module OpencodeUsage
  Summary = Struct.new(:tokens_in, :tokens_out, :tokens_reasoning, :cache_read, :cache_write, :cost, :steps,
    :outcome, :error_type, keyword_init: true)

  RATE_LIMIT = /rate.?limit|too many requests|quota|\b429\b|free usage limit/i
  AUTH_FAILURE = /unauthori[sz]ed|api.?key|forbidden|credential|\b40[13]\b/i
  TIMEOUT = /time.?out|timed out/i

  module_function

  # raw: the CLI's combined stdout/stderr. reply: the extracted reply text,
  # used only to tell "no reply" from "reply". timed_out: the caller's timeout.
  def parse(raw, reply_present:, timed_out: false)
    tokens = Hash.new(0)
    cost = 0.0
    steps = 0
    error = nil
    raw.to_s.each_line do |line|
      event = parse_line(line)
      if event.nil?
        error ||= classify(line) if line.match?(/error|unrecognized|invalid/i)
        next
      end
      case event['type']
      when 'step_finish'
        steps += 1
        add_tokens(tokens, event.dig('part', 'tokens'))
        cost += event.dig('part', 'cost').to_f
      when 'error'
        error ||= classify(event['error'].to_json)
      end
    end
    outcome, error_type = outcome_for(error: error, timed_out: timed_out, reply_present: reply_present, steps: steps)
    Summary.new(tokens_in: tokens[:input], tokens_out: tokens[:output], tokens_reasoning: tokens[:reasoning],
      cache_read: tokens[:cache_read], cache_write: tokens[:cache_write], cost: cost.round(6),
      steps: steps, outcome: outcome, error_type: error_type)
  end

  # Writes the run. Monitoring must never break the agent, so failures only log.
  def record!(summary, model:, duration_ms:)
    AiAgentRun.create!(
      model: model, outcome: summary.outcome, error_type: summary.error_type, tokens_in: summary.tokens_in,
      tokens_out: summary.tokens_out, tokens_reasoning: summary.tokens_reasoning,
      cache_read_tokens: summary.cache_read, cache_write_tokens: summary.cache_write, cost_usd: summary.cost,
      steps: summary.steps, duration_ms: duration_ms, occurred_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.warn "[OpencodeUsage] could not record run: #{e.class}"
    nil
  end

  def parse_line(line)
    data = JSON.parse(line)
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  def add_tokens(tokens, found)
    return unless found.is_a?(Hash)

    tokens[:input] += found['input'].to_i
    tokens[:output] += found['output'].to_i
    tokens[:reasoning] += found['reasoning'].to_i
    cache = found['cache']
    return unless cache.is_a?(Hash)

    tokens[:cache_read] += cache['read'].to_i
    tokens[:cache_write] += cache['write'].to_i
  end

  def classify(text)
    return 'rate_limited' if text.match?(RATE_LIMIT)
    return 'auth' if text.match?(AUTH_FAILURE)
    return 'timeout' if text.match?(TIMEOUT)

    'cli_error'
  end

  def outcome_for(error:, timed_out:, reply_present:, steps:)
    return ['timeout', 'timeout'] if timed_out
    return ['ok', nil] if reply_present
    return ['rate_limited', 'rate_limited'] if error == 'rate_limited'
    return ['error', error] if error

    # No reply and no error: the CLI printed nothing usable (a flag it no
    # longer accepts, a crash) or the model chose to stay silent.
    steps.positive? ? ['empty', nil] : ['error', 'no_output']
  end
end
