# frozen_string_literal: true

class ClockShift < ApplicationRecord
  include TenantScoped

  belongs_to :user, optional: true
  belongs_to :employee, class_name: 'People::Employee', optional: true
  has_many :corrections, class_name: 'ClockCorrection', dependent: :restrict_with_exception

  attr_readonly :tenant_id, :user_id, :employee_id, :employee_key, :employee_name, :employment_type, :request_token
  validates :tenant_id, :employee_key, :employee_name, :employment_type, :started_at, :request_token, presence: true
  validates :request_token, format: { with: /\A[a-zA-Z0-9_-]{16,64}\z/ }
  validate :ordered_interval
  validate :non_overlapping_interval
  validate :linked_worker, on: :create

  scope :open, -> { where(ended_at: nil) }
  scope :recent, -> { order(started_at: :desc, id: :desc) }

  def hours(at: Time.current)
    [(ended_at || at) - started_at, 0].max / 3600.0
  end

  # All changes for one worker share a writer lock before interval reads.
  # A missing historical worker falls back to the tenant row, retaining the
  # ability to close/review shifts after employee deletion.
  def self.serialize_worker(employee_key)
    raise ActiveRecord::RecordNotFound unless Current.tenant_id.present?

    transaction do
      locked = People::Employee.where(id: employee_key).update_all('updated_at = updated_at')
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at') if locked.zero?
      yield
    end
  end

  def serialize_change
    raise ActiveRecord::RecordNotFound unless Current.tenant_id.present? && tenant_id == Current.tenant_id

    self.class.serialize_worker(employee_key) do
      self.class.where(id: id).update_all('lock_version = lock_version + 1')
      reload
      yield
    end
  end

  private

  def ordered_interval
    return if started_at.nil?

    errors.add(:started_at, 'cannot be in the future') if started_at > Time.current
    errors.add(:ended_at, 'must be after clock-in') if ended_at && ended_at <= started_at
    errors.add(:ended_at, 'cannot be in the future') if ended_at && ended_at > Time.current
  end

  def non_overlapping_interval
    return if started_at.nil? || employee_key.blank?

    scope = self.class.where(employee_key: employee_key).where.not(id: id)
    scope = scope.where('ended_at IS NULL OR ended_at > ?', started_at)
    scope = scope.where('started_at < ?', ended_at) if ended_at
    errors.add(:base, 'This interval overlaps another shift for this worker') if scope.exists?
  end

  def linked_worker
    return if user&.active? && employee&.active? && employee.user_id == user_id &&
      employee.tenant_id == tenant_id && employee_key == employee.id.to_s

    errors.add(:employee, 'must be an active worker linked to this sign-in account and store')
  end
end
