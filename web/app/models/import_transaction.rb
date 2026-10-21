# frozen_string_literal: true

# A group of staged lines that together make one balanced accounting
# transaction. journal_entry_id links the imported record back to the books.
class ImportTransaction < ApplicationRecord
  include TenantScoped

  encrypts :name

  STATUSES = %w[staged posted rejected duplicate reversed discarded].freeze

  belongs_to :batch, class_name: 'ImportBatch', inverse_of: :transactions
  belongs_to :journal_entry, class_name: 'Finance::JournalEntry', optional: true
  has_many :lines, class_name: 'ImportLine', foreign_key: :transaction_id, inverse_of: :import_transaction, dependent: :restrict_with_exception

  validates :txn_key, :fingerprint, :txn_date, presence: true
  validates :status, inclusion: { in: STATUSES }
  before_destroy { throw :abort }

  scope :staged, -> { where(status: 'staged') }
  scope :posted, -> { where(status: 'posted') }

  def balanced? = debit_cents == credit_cents
end
