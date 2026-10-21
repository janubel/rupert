# frozen_string_literal: true

# A single Google Drive SQLite snapshot backup attempt, uploaded to Drive with
# its link and any error recorded for verification.
class BackupLog < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'BackupLog'
  self.primary_key = 'id'

  STATUSES = %w[running success failed].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :startedAt, presence: true

  scope :recent, ->(limit = 10) { order(startedAt: :desc).limit(limit) }

  def self.latest
    recent(1).first
  end

  def self.latest_success
    where(status: 'success').order(startedAt: :desc).first
  end

  def success?
    status == 'success'
  end
end
