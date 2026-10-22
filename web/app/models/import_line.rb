# frozen_string_literal: true

# One parsed row of an outside export. Money is integer cents; names, memos and
# the raw row are encrypted at rest. Rows are never deleted, only given a status.
class ImportLine < ApplicationRecord
  include TenantScoped

  encrypts :name
  encrypts :memo
  encrypts :raw_json

  STATUSES = %w[staged rejected duplicate posted reversed discarded].freeze
  RECORD_TYPES = %w[transaction_line account vendor customer balance].freeze

  belongs_to :batch, class_name: 'ImportBatch', inverse_of: :lines
  belongs_to :import_transaction, class_name: 'ImportTransaction', foreign_key: :transaction_id, inverse_of: :lines, optional: true

  validates :row_no, :fingerprint, presence: true
  validates :record_type, inclusion: { in: RECORD_TYPES }
  validates :status, inclusion: { in: STATUSES }
  before_destroy { throw :abort }

  scope :rejected, -> { where(status: 'rejected') }

  def raw = raw_json.present? ? JSON.parse(raw_json) : {}
end
