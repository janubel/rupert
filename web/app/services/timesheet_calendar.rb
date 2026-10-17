# frozen_string_literal: true

# Read-only week grid for administrators: worked time placed at the actual time
# of day. Rupert clock shifts, Square timecards and C-Trax shifts are separate
# sources and are drawn as separate, labelled blocks; nothing here is summed,
# approved or written back.
class TimesheetCalendar
  Block = Struct.new(:employee_id, :employee_name, :source, :starts_at, :ends_at, :open, :past, :lane, :lanes, keyword_init: true) do
    def day = starts_at.to_date
    def top_percent = (starts_at.seconds_since_midnight / 86_400.0 * 100).round(3)

    def height_percent
      finish = ends_at.to_date == starts_at.to_date ? ends_at : starts_at.end_of_day
      [((finish - starts_at) / 86_400.0 * 100), 1.2].max.round(3)
    end

    def label = "#{starts_at.strftime('%-l:%M%P')} – #{open ? 'now' : ends_at.strftime('%-l:%M%P')}"
  end

  attr_reader :week, :blocks, :employees

  def initialize(week_start, user:)
    @week = week_start
    @now = Time.current
    range = week_start.beginning_of_day...(week_start + 7).beginning_of_day
    raw = clock_blocks(range) + square_blocks(range, user) + ctrax_blocks(range, user)
    @blocks = layout(raw)
    @employees = raw.map { |b| [b.employee_id, b.employee_name] }.uniq.sort_by { |_id, name| name.to_s.downcase }
  end

  def blocks_for(day) = @blocks.select { |b| b.day == day }

  private

  def build(employee_id, name, source, from, to)
    finish = to || @now
    Block.new(employee_id: employee_id, employee_name: name, source: source, starts_at: from.in_time_zone,
      ends_at: [finish, from + 1.minute].max.in_time_zone, open: to.nil?, past: !to.nil? && to < @now)
  end

  def clock_blocks(range)
    ClockShift.where(started_at: range).where.not(employee_id: nil).includes(:employee).filter_map do |shift|
      build(shift.employee_id, shift.employee_name, 'Rupert clock', shift.started_at, shift.ended_at)
    end
  end

  def square_blocks(range, user)
    SquareTimecard.visible_to(user).where(started_at: range).where.not(employee_id: nil).includes(:employee).filter_map do |card|
      build(card.employee_id, card.employee&.name, 'Square', card.started_at, card.ended_at)
    end
  end

  def ctrax_blocks(range, user)
    CtraxLaborShift.visible_to(user).where(started_at: range).where.not(employee_id: nil).includes(:employee).filter_map do |shift|
      build(shift.employee_id, shift.employee&.name, 'C-Trax', shift.started_at, shift.ended_at)
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
