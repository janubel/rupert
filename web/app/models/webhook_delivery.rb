# frozen_string_literal: true

# One inbound webhook delivery. The (provider, delivery_id) pair is unique, so
# the INSERT itself is the deduplication lock: a replay of an already-recorded
# delivery raises RecordNotUnique and is acknowledged without a second job.
class WebhookDelivery < ApplicationRecord
  RETENTION = 30.days
  STATUSES = %w[queued processed failed duplicate].freeze

  validates :provider, :delivery_id, :topic, :received_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :stale, -> { where('received_at < ?', RETENTION.ago) }

  # Returns the new record, or nil when this delivery id was already seen.
  # A missing delivery id (non-Shopify callers, local tests) is recorded with
  # a random id so it is never mistaken for a duplicate.
  def self.record!(provider:, delivery_id:, topic:, shop_domain: nil)
    create!(provider: provider, delivery_id: delivery_id.presence || "untracked-#{SecureRandom.uuid}",
      topic: topic, shop_domain: shop_domain, received_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def self.prune!
    stale.delete_all
  end
end
