# frozen_string_literal: true

# Calculates the compensation figures shown on a timesheet:
#   - commission: 1% of credited period sales
#   - card bonus: a fixed bonus per employee 50%-off card redemption
#
# Display figures only. This does not post to payroll and does not create payslips.
class TimesheetCompensation
  COMMISSION_RATE = 0.01
  CARD_BONUS_CENTS = 1000

  def self.calculate(sales_cents:, card_redemptions:)
    sales = sales_cents.to_i
    redemptions = card_redemptions.to_i
    commission = (sales * COMMISSION_RATE).round
    bonus = redemptions * CARD_BONUS_CENTS
    { sales_cents: sales, commission_cents: commission, card_redemptions: redemptions,
      card_bonus_cents: bonus, total_cents: commission + bonus }
  end
end
