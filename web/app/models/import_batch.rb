# frozen_string_literal: true

# One reviewed import of one file. A batch only ever stages rows; approving it
# (see QuickbooksPosting) is the single step that creates journal entries, and
# closing it reverses them again. Counts and the summary describe the file as
# parsed, not the books.
class ImportBatch < ApplicationRecord
  include TenantScoped

  encrypts :summary_json

  STATUSES = %w[staged approved discarded reversed].freeze
  POSTING_KINDS = %w[journal].freeze
  KIND_LABELS = { 'chart_of_accounts' => 'Chart of accounts', 'journal' => 'Journal (transactions)', 'vendors' => 'Vendors',
                  'customers' => 'Customers', 'trial_balance' => 'Trial balance (reconciliation only)' }.freeze

  belongs_to :source_document, class_name: 'ImportSourceDocument'
  has_many :transactions, class_name: 'ImportTransaction', foreign_key: :batch_id, inverse_of: :batch, dependent: :restrict_with_exception
  has_many :lines, class_name: 'ImportLine', foreign_key: :batch_id, inverse_of: :batch, dependent: :restrict_with_exception

  validates :source, inclusion: { in: ImportSourceDocument::SOURCES }
  validates :kind, inclusion: { in: ImportSourceDocument::KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :filename, :summary_json, presence: true
  before_destroy { throw :abort }

  scope :newest, -> { order(id: :desc) }
  scope :live, -> { where(status: %w[staged approved]) }

  def summary = JSON.parse(summary_json)
  def kind_label = KIND_LABELS.fetch(kind, kind.humanize)
  def staged? = status == 'staged'
  def approved? = status == 'approved'
  def postable? = POSTING_KINDS.include?(kind)
end
