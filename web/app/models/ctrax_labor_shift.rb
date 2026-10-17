# frozen_string_literal: true

# Historical observations only. These rows never generate payable time.
class CtraxLaborShift < ApplicationRecord
  include TenantScoped
  STATUSES = %w[imported open unmatched conflict invalid changed missing deleted unassigned].freeze
  belongs_to :employee, class_name: 'People::Employee', optional: true
  has_many :observations, class_name: 'CtraxLaborObservation', dependent: :restrict_with_exception
  encrypts :source_payload, :latest_payload
  attr_readonly :tenant_id, :source_origin, :external_id, :source_payload, :original_digest
  validates :source_origin, :external_id, :user_external_id, :status, :last_seen_at,
    :original_digest, :latest_digest, presence: true
  validates :external_id, uniqueness: { scope: %i[tenant_id source_origin] }
  validates :status, inclusion: { in: STATUSES }
  validates :store_id, presence: true, unless: -> { status == 'unassigned' }
  validates :employee, presence: true, if: -> { status == 'unassigned' }
  validate :same_workspace

  def latest_record
    JSON.parse(latest_payload)
  rescue JSON::ParserError, TypeError
    {}
  end

  def hours
    reported_hours
  end

  def self.visible_to(user)
    return none unless Current.tenant&.status == 'active' && user&.active? && (user.super_admin? || user.tenant_id == Current.tenant_id)
    return all if user.can_review_timesheets? || (user.can_manage_accounts? && user.can?('timesheets.read'))

    worker = TimeClockService.worker_for(user, include_on_leave: true)
    worker ? where(employee_id: worker.id) : none
  end

  private

  def same_workspace
    errors.add(:employee, 'must belong to this workspace') if employee && employee.tenant_id != tenant_id
  end
end
