# frozen_string_literal: true

# One provider check of the opencode integration (see OpencodeHealth). A row is
# a set of classifications and counts: the API key and any response text are
# never stored.
class AiHealthCheck < ApplicationRecord
  STATUSES = %w[ok warning error not_configured].freeze
  KEY_STATES = %w[valid invalid expired missing unchecked].freeze
  MODEL_STATES = %w[available missing unknown].freeze
  # A check older than this means the periodic job is not running.
  STALE_AFTER = 3.hours

  serialize :free_models, coder: JSON
  attribute :free_models, default: -> { [] }

  validates :status, inclusion: { in: STATUSES }
  validates :key_state, inclusion: { in: KEY_STATES }
  validates :model_state, inclusion: { in: MODEL_STATES }
  validates :checked_at, presence: true

  scope :latest_first, -> { order(checked_at: :desc, id: :desc) }

  def self.latest = latest_first.first

  def stale?(now: Time.current) = checked_at < now - STALE_AFTER
end
