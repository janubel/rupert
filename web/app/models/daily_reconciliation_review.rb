# frozen_string_literal: true

class DailyReconciliationReview < ApplicationRecord
  include TenantScoped
  encrypts :notes
  belongs_to :reviewed_by, class_name: 'User', optional: true
  validates :day, :report_digest, :tenant_id, presence: true
  validates :status, inclusion: { in: %w[needs_attention reviewed] }
  validates :notes, presence: true, length: { maximum: 4000 }
  before_update { throw :abort }
  before_destroy { throw :abort }
end
