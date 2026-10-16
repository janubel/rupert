# frozen_string_literal: true

class ReconciliationFollowUp < ApplicationRecord
  include TenantScoped
  STATUSES = { 'open' => 'Open', 'waiting' => 'Waiting on report / response', 'closed' => 'Closed by reviewer' }.freeze
  CATEGORIES = { 'missing_report' => 'Report request', 'difference' => 'Difference investigation' }.freeze
  DOCUMENT_KINDS = ReconciliationDocument::KINDS.excluding('daily_archive', 'period_archive').freeze
  CONTEXT = %w[tenant_id category source document_kind period_from period_to currency location_id metric report_digest submission_key created_by_id].freeze
  encrypts :title
  encrypts :notes
  belongs_to :owner, -> { where(tenant_id: Current.tenant_id) }, class_name: 'User', optional: true
  belongs_to :created_by, -> { where(tenant_id: Current.tenant_id) }, class_name: 'User', optional: true
  belongs_to :document, class_name: 'ReconciliationDocument', optional: true
  has_many :events, class_name: 'ReconciliationFollowUpEvent'
  scope :active, -> { where(status: %w[open waiting]) }
  scope :covering, ->(day) { where('period_from <= ? AND period_to >= ?', day, day) }
  validates :title, :notes, :due_on, :period_from, :period_to, :tenant_id, presence: true
  validates :title, length: { maximum: 200 }
  validates :notes, length: { maximum: 4000 }
  validates :submission_key, format: { with: /\A[0-9a-f-]{36}\z/ }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :category, inclusion: { in: CATEGORIES.keys }
  validates :source, inclusion: { in: ReconciliationDocument::SOURCES.excluding('rupert') }
  validates :document_kind, inclusion: { in: DOCUMENT_KINDS }
  validates :metric, inclusion: { in: ReconciliationEvidence::AMOUNTS }, allow_blank: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }, allow_blank: true
  validate :valid_context
  validate :workspace_associations
  after_save :retain_history, if: :saved_changes?
  before_destroy { throw :abort }

  def overdue?
    status != 'closed' && due_on && due_on < Date.current
  end

  def matching_documents
    candidates = ReconciliationDocument.where(tenant_id: tenant_id, source: source, kind: document_kind)
      .where('period_from <= ? AND period_to >= ?', period_from, period_to)
      .select(:id, :tenant_id, :source, :kind, :filename, :metadata_json, :period_from, :period_to, :supersedes_id).order(id: :desc).limit(100)
    candidates.select { |doc| document_matches?(doc) }
  end

  def document_matches?(doc)
    doc && doc.tenant_id == tenant_id && doc.source == source && doc.kind == document_kind &&
      doc.period_from <= period_from && doc.period_to >= period_to &&
      (document_kind != 'register_control' || (doc.metadata['currency'] == currency && doc.metadata['location_id'].presence == location_id.presence))
  end

  private

  def valid_context
    errors.add(:period_to, 'must follow the start date within 366 days') if period_from && period_to && !(period_to - period_from).between?(0, 365)
    if document_kind == 'register_control' && (period_from != period_to || currency.blank?)
      errors.add(:base, 'A register-control request needs one business day and a currency.')
    end
    errors.add(:base, 'Create a new follow-up to change its original source, period or purpose.') if persisted? && CONTEXT.any? { |key| will_save_change_to_attribute?(key) }
  end

  def workspace_associations
    if owner_id.present?
      candidate = User.active.find_by(id: owner_id, tenant_id: tenant_id)
      errors.add(:owner, 'must be an active report reader in this workspace') unless candidate&.can?('reports.read')
    end
    creator = User.find_by(id: created_by_id) if created_by_id
    errors.add(:created_by, 'must belong to this workspace or be a platform administrator') if created_by_id && !(creator && (creator.tenant_id == tenant_id || creator.super_admin?))
    if document_id.present?
      candidate = ReconciliationDocument.find_by(id: document_id, tenant_id: tenant_id)
      errors.add(:document, 'must match this source, kind, covered period and control scope') unless period_from && period_to && document_matches?(candidate)
    end
  end

  def retain_history
    actor = Current.user if Current.user && (Current.user.tenant_id == tenant_id || Current.user.super_admin?)
    events.create!(tenant_id: tenant_id, details_json: {
      title: title, status: status, notes: notes, due_on: due_on.iso8601, owner_id: owner_id, owner_name: owner&.display_name,
      document_id: document_id, actor_id: actor&.id, actor_name: actor&.display_name || 'System', version: lock_version
    }.to_json)
  end
end
