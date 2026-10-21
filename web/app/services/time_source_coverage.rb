# frozen_string_literal: true

# Per-source summary of retained time records: how many, how far back they
# reach, when the source was last read and how many are held out of totals.
# Read-only; the oldest stored record is evidence of coverage, not proof that
# nothing older exists at the source.
class TimeSourceCoverage
  Source = Struct.new(:key, :label, :records, :first_at, :last_at, :last_read_at, :held, :held_label, :hours, :path, keyword_init: true)

  def self.for(user)
    new(user).sources
  end

  def initialize(user)
    @user = user
  end

  def sources
    [rupert, square, ctrax]
  end

  private

  def rupert
    scope = ClockShift.all
    scope = scope.where(employee_id: worker_id) unless all_employees?
    Source.new(key: 'rupert', label: 'Rupert clock', records: scope.count,
      first_at: scope.minimum(:started_at), last_at: scope.maximum(:started_at), last_read_at: scope.maximum(:updated_at),
      held: scope.where(ended_at: nil).count, held_label: 'still punched in',
      hours: scope.where.not(ended_at: nil).to_a.sum(&:hours).round(1), path: nil)
  end

  def square
    scope = SquareTimecard.visible_to(@user)
    Source.new(key: 'square', label: 'Square timecards', records: scope.count,
      first_at: scope.minimum(:started_at), last_at: scope.maximum(:started_at), last_read_at: last_success('square'),
      held: scope.where(imported_at: nil).count, held_label: 'open, conflict or unmatched',
      hours: (BigDecimal(scope.counted.sum(:payable_seconds).to_s) / 3600).round(1), path: :square)
  end

  def ctrax
    scope = CtraxLaborShift.visible_to(@user)
    Source.new(key: 'ctrax', label: 'C-Trax shifts', records: scope.count,
      first_at: scope.minimum(:started_at), last_at: scope.maximum(:started_at), last_read_at: last_success('ctrax'),
      held: scope.where.not(status: 'imported').count, held_label: 'awaiting match or review',
      hours: (scope.where(status: 'imported').sum(:reported_hours) || 0).round(1), path: :ctrax)
  end

  def last_success(source)
    SyncAttempt.where(source: source, operation: 'timecards', status: 'succeeded').maximum(:finished_at)
  end

  def all_employees?
    @user.can_review_timesheets? || (@user.can_manage_accounts? && @user.can?('timesheets.read'))
  end

  def worker_id
    TimeClockService.worker_for(@user, include_on_leave: true)&.id || -1
  end
end
