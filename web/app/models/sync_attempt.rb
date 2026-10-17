# frozen_string_literal: true

# Observability metadata only. Never persist arguments, responses or messages.
class SyncAttempt < ApplicationRecord
  include TenantScoped

  OPERATIONS = {
    'ctrax' => %w[stock sales timecards], 'swipesimple' => %w[web], 'bank' => %w[web reporting],
    'authorize_net' => %w[reporting events], 'shopify' => %w[catalog],
    'square' => %w[catalog timecards], 'google_backup' => %w[backup]
  }.freeze
  STATUSES = %w[queued running succeeded failed skipped].freeze

  validates :source, inclusion: { in: OPERATIONS.keys }
  validates :operation, inclusion: { in: ->(record) { OPERATIONS.fetch(record.source, []) } }
  validates :status, inclusion: { in: STATUSES }
  validates :error_category, inclusion: { in: ->(_) { SyncFailure::GUIDANCE.keys } }, allow_nil: true
  validates :queued_at, presence: true
  validates :tenant_id, presence: true, unless: -> { source == 'google_backup' }
  before_validation { self.tenant_id = nil if source == 'google_backup' }
end
