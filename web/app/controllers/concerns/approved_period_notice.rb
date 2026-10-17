# frozen_string_literal: true

# When a money-out record dated inside an already-approved day or week is
# added, changed or removed, say so plainly and put it in the audit trail. The
# edit is allowed (books get corrected), but the approval will now read
# "changed since approval" until someone looks again.
module ApprovedPeriodNotice
  extend ActiveSupport::Concern

  private

  def note_approved_period(date, what)
    return if date.blank?

    approval = BookApproval.where('period_from <= ? AND period_to >= ?', date, date).chronological.last
    return unless approval&.approved?

    ActivityLogger.log('edit_in_approved_period',
      details: "#{what} dated #{date} changed books approved by #{approval.approved_by_name} on #{approval.approved_at.to_date}")
    flash[:alert] = "Saved. #{date.strftime('%b %-d')} was approved by #{approval.approved_by_name}; that approval now shows as changed and needs a fresh look."
  end

  def change_summary(record, skip: %w[updated_at])
    record.saved_changes.except(*skip).map { |attr, (from, to)| "#{attr}: #{from.inspect} -> #{to.inspect}" }.join('; ').truncate(480)
  end
end
