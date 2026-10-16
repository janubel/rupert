# frozen_string_literal: true

class SquareTimecardDay < ApplicationRecord
  include TenantScoped
  belongs_to :square_timecard
  attr_readonly :tenant_id, :square_timecard_id, :worked_on, :payable_seconds
  validates :worked_on, presence: true
  validates :payable_seconds, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 90_000 }
  validate :same_workspace

  def hours
    BigDecimal(payable_seconds.to_s) / 3600
  end

  def work_type
    'recorded'
  end

  def timesheet
    square_timecard
  end

  def notes
    "Square timecard #{square_timecard.external_id}; unpaid breaks deducted"
  end

  def estimated_cents
    card = square_timecard
    return unless card.currency == 'USD' && card.hourly_rate_cents&.positive?

    (hours * card.hourly_rate_cents).round.to_i
  end

  private

  def same_workspace
    errors.add(:square_timecard, 'must belong to this workspace') unless square_timecard&.tenant_id == tenant_id && square_timecard.imported_at
  end
end
