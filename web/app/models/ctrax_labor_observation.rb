# frozen_string_literal: true

# Append-only source/status evidence, including corrections and disappearance.
class CtraxLaborObservation < ApplicationRecord
  include TenantScoped
  belongs_to :ctrax_labor_shift
  encrypts :payload
  validates :sequence, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :ctrax_labor_shift_id }
  validates :observed_at, :digest, :payload, presence: true
  validate :same_workspace

  def readonly?
    persisted? || super
  end

  def record_data
    envelope.fetch('record', {})
  end

  def status
    envelope['status']
  end

  def issue
    envelope['issue']
  end

  private

  def envelope
    JSON.parse(payload)
  rescue JSON::ParserError, TypeError
    {}
  end

  def same_workspace
    if ctrax_labor_shift && ctrax_labor_shift.tenant_id != tenant_id
      errors.add(:ctrax_labor_shift, 'must belong to this workspace')
    end
  end
end
