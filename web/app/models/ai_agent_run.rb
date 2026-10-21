# frozen_string_literal: true

# Token usage and outcome of one opencode run by the @rupert Buzz agent, read
# from the CLI's own JSON output (OpencodeUsage). Counters only: no prompt, no
# reply, no channel content.
class AiAgentRun < ApplicationRecord
  OUTCOMES = %w[ok error rate_limited timeout empty].freeze

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :occurred_at, presence: true

  scope :since, ->(time) { where(occurred_at: time..) }

  def total_tokens = tokens_in + tokens_out + tokens_reasoning
end
