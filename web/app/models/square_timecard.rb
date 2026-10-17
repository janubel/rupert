# frozen_string_literal: true

# A read-only historical source, separate from new payable Rupert timesheets.
class SquareTimecard < ApplicationRecord
  STATUSES = %w[imported open unmatched conflict invalid changed missing].freeze
  include TenantScoped
  belongs_to :employee, class_name: 'People::Employee', optional: true
  has_many :days, class_name: 'SquareTimecardDay', dependent: :restrict_with_exception
  encrypts :source_payload, :latest_payload
  attr_readonly :tenant_id, :external_id
  validates :external_id, :import_status, :last_seen_at, presence: true
  validates :external_id, uniqueness: { scope: :tenant_id }
  validates :import_status, inclusion: { in: STATUSES }
  validate :same_workspace

  scope :counted, -> { where.not(imported_at: nil) }

  def hours
    BigDecimal(payable_seconds.to_s) / 3600
  end

  def status
    import_status
  end

  def self.visible_to(user)
    return none unless user&.active? && (user.super_admin? || user.tenant_id == Current.tenant_id)
    return all if user.can_review_timesheets? || (user.can_manage_accounts? && user.can?('timesheets.read'))

    worker = TimeClockService.worker_for(user, include_on_leave: true)
    worker ? where(employee_id: worker.id) : none
  end

  def self.overlapping(employee_id, start_at, end_at)
    scope = counted.where('payable_seconds > 0').where(employee_id: employee_id).where('ended_at > ?', start_at)
    end_at ? scope.where('started_at < ?', end_at) : scope
  end

  private

  def same_workspace
    errors.add(:employee, 'must belong to this workspace') if employee && employee.tenant_id != tenant_id
  end
end
