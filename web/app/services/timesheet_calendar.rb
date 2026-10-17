# frozen_string_literal: true

# Read-only week grid for administrators: worked time placed at the actual time
# of day. Rupert clock shifts, Square timecards and C-Trax shifts are separate
# sources and are drawn as separate, labelled blocks; nothing here is summed,
# approved or written back.
class TimesheetCalendar
  Block = Struct.new(:employee_id, :employee_name, :source, :unmatched, :starts_at, :ends_at, :open, :past, :lane, :lanes, keyword_init: true) do
    def day = starts_at.to_date
    def top_percent = (starts_at.seconds_since_midnight / 86_400.0 * 100).round(3)

    def height_percent
      finish = ends_at.to_date == starts_at.to_date ? ends_at : starts_at.end_of_day
      [((finish - starts_at) / 86_400.0 * 100), 1.2].max.round(3)
    end

    def hours = ((ends_at - starts_at) / 3600.0).round(2)
    def label = "#{starts_at.strftime('%-l:%M%P')} – #{open ? 'now' : ends_at.strftime('%-l:%M%P')}"
  end

  Entry = Struct.new(:employee_id, :employee_name, :day, :hours, :work_type, keyword_init: true)

  attr_reader :week, :blocks, :employees, :entries

  def initialize(week_start, user:)
    @week = week_start
    @now = Time.current
    range = week_start.beginning_of_day...(week_start + 7).beginning_of_day
    raw = clock_blocks(range) + square_blocks(range, user) + ctrax_blocks(range, user)
    @blocks = layout(raw)
    @entries = manual_entries(user)
    @employees = (raw.map { |b| [b.employee_id, b.employee_name] } + @entries.map { |e| [e.employee_id, e.employee_name] })
      .uniq.sort_by { |_id, name| name.to_s.downcase }
  end

  def blocks_for(day) = @blocks.select { |b| b.day == day }
  def entries_for(day) = @entries.select { |e| e.day == day }
  def clocked_in = @blocks.select(&:open)

  # Hours per employee and source. Sources overlap, so they are never added together.
  def hours_by_employee
    @blocks.group_by(&:employee_id).transform_values do |list|
      list.group_by(&:source).transform_values { |b| b.sum(&:hours).round(1) }
    end
  end

  private

  def build(employee_id, name, source, from, to, unmatched: false)
    finish = to || @now
    Block.new(employee_id: employee_id, employee_name: name, source: source, unmatched: unmatched, starts_at: from.in_time_zone,
      ends_at: [finish, from + 1.minute].max.in_time_zone, open: to.nil?, past: !to.nil? && to < @now)
  end

  # Overlap with the week, so shifts that began the night before or are still open show up.
  def overlapping(scope, column_start = :started_at, column_end = :ended_at)
    scope.where(column_start => ...@range_end).where("#{column_end} IS NULL OR #{column_end} >= ?", @range_start)
  end

  def clock_blocks(range)
    @range_start = range.begin
    @range_end = range.end
    overlapping(ClockShift.all).includes(:employee).filter_map do |shift|
      build(shift.employee_id || "clock-#{shift.employee_key}", shift.employee_name, 'Rupert clock', shift.started_at, shift.ended_at)
    end
  end

  def square_blocks(_range, user)
    overlapping(SquareTimecard.visible_to(user).where.not(started_at: nil)).includes(:employee).filter_map do |card|
      build(card.employee_id || "square-#{card.team_member_id}", card.employee&.name || "Unmatched Square #{card.team_member_id.to_s.last(6)}".strip,
        'Square', card.started_at, card.ended_at, unmatched: card.employee_id.nil?)
    end
  end

  def ctrax_blocks(_range, user)
    overlapping(CtraxLaborShift.visible_to(user).where.not(started_at: nil)).includes(:employee).filter_map do |shift|
      build(shift.employee_id || "ctrax-#{shift.user_external_id}", shift.employee&.name || "Unmatched C-Trax #{shift.user_external_id.to_s.last(6)}",
        'C-Trax', shift.started_at, shift.ended_at, unmatched: shift.employee_id.nil?)
    end
  end

  # Hours typed onto a timesheet with no clock times: shown per day, not on the time grid.
  def manual_entries(user)
    sheets = People::TimesheetPolicy.visible_to(user).select(:id)
    People::TimesheetEntry.where(timesheet_id: sheets, clock_shift_id: nil, worked_on: @week..(@week + 6))
      .includes(timesheet: :employee).filter_map do |entry|
      employee = entry.timesheet.employee
      next unless employee

      Entry.new(employee_id: employee.id, employee_name: employee.name, day: entry.worked_on, hours: entry.hours, work_type: entry.work_type)
    end
  end

  # Greedy side-by-side lanes per day so overlapping blocks stay readable.
  def layout(blocks)
    blocks.group_by(&:day).each_value do |day_blocks|
      cluster = []
      cluster_end = nil
      flush = lambda do
        width = (cluster.map(&:lane).max || 0) + 1
        cluster.each { |b| b.lanes = width }
        cluster = []
      end
      day_blocks.sort_by(&:starts_at).each do |block|
        flush.call if cluster_end && block.starts_at >= cluster_end
        taken = cluster.select { |c| c.ends_at > block.starts_at }.map(&:lane)
        block.lane = (0..).find { |n| taken.exclude?(n) }
        cluster << block
        cluster_end = [cluster_end, block.ends_at].compact.max
      end
      flush.call
    end
    blocks
  end
end
