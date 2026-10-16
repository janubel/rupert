# frozen_string_literal: true

require 'digest'

class SquareTimecardImport
  class Error < StandardError; end
  RELEVANT = %w[id team_member_id location_id timezone start_at end_at status wage breaks].freeze

  def initialize(actor: Current.user, rows: nil)
    @actor, @rows = actor, rows
  end

  # Dry-run is the default. A complete source read precedes every publication.
  def call(apply: false)
    authorize!
    if @rows.nil?
      @reader = SquareTimecardReader.new
      @rows = @reader.call
    end
    ids = @rows.map { |row| row.is_a?(Hash) && row['id'] }
    raise Error, 'Invalid or duplicate source timecards.' unless ids.all? { |id| id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,255}\z/) } && ids.uniq.size == ids.size && ids.size <= 100_000

    @reader&.verify_connection!
    return result(build_plan) unless apply

    SquareTimecard.transaction do
      raise ActiveRecord::RecordNotFound unless Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at') == 1

      authorize!
      @reader&.verify_connection!
      plan = build_plan
      now = Time.current
      stats = result(plan)
      plan.each { |item| publish(item, now) }
      SquareTimecard.where.not(external_id: ids).where.not(import_status: 'missing').update_all(import_status: 'missing', issue: 'Not returned by the latest complete Square read; retained for review.', updated_at: now)
      ActivityLogger.log('square_timecards_imported', details: stats.to_json)
      stats
    end
  end

  private

  def authorize!
    @actor = User.find_by(id: @actor&.id, active: true)
    raise Pundit::NotAuthorizedError unless @actor&.active? && @actor.can_manage_accounts? && @actor.can?('timesheets.write') && Current.tenant&.status == 'active' && (@actor.super_admin? || @actor.tenant_id == Current.tenant_id)
  end

  def build_plan
    identities = EmployeeSourceIdentity.where(source: 'square').includes(:employee).index_by(&:external_id)
    @existing = SquareTimecard.includes(:days).index_by(&:external_id)
    plan = @rows.map do |row|
      old = @existing[row['id']]
      worker = identities[row['team_member_id']]&.employee
      item = normalize(row).merge(row: row, old: old, employee: worker)
      if old&.imported_at
        changed = old.original_digest != item[:digest] || old.employee_id != worker&.id
        item[:state] = changed ? 'changed' : 'imported'
        item[:issue] = changed ? 'Square source or employee mapping changed; original imported hours retained for review.' : nil
      elsif !worker
        item[:state] = 'unmatched'
        item[:issue] = 'No consolidated employee has this Square team-member identity.'
      end
      item
    end
    check_overlaps(plan)
    plan
  end

  def normalize(row)
    digest = Digest::SHA256.hexdigest(JSON.generate(canonical(row.slice(*RELEVANT))))
    result = { digest: digest, state: 'invalid', days: [], attributes: {} }
    zone = Time.find_zone!(row.fetch('timezone'))
    start_at = timestamp(row.fetch('start_at'))
    raise ArgumentError unless start_at <= Time.current && row['team_member_id'].is_a?(String) && row['team_member_id'].present? && row['location_id'].is_a?(String) && row['location_id'].present?

    if row['status'] == 'OPEN' && row['end_at'].blank?
      return result.merge(state: 'open', issue: 'Open Square timecard; no hours counted until it closes.')
    end
    raise ArgumentError unless row['status'] == 'CLOSED'

    end_at = timestamp(row.fetch('end_at'))
    raise ArgumentError unless end_at >= start_at && end_at <= Time.current && end_at - start_at <= 31.days

    breaks = row.fetch('breaks', [])
    raise ArgumentError unless breaks.is_a?(Array)

    intervals = breaks.map do |pause|
      a, b = timestamp(pause.fetch('start_at')), timestamp(pause.fetch('end_at'))
      raise ArgumentError unless [true, false].include?(pause['is_paid']) && a >= start_at && b <= end_at && b >= a
      [a, b, pause['is_paid']]
    end.sort_by(&:first)
    raise ArgumentError if intervals.each_cons(2).any? { |a, b| a[1] > b[0] }

    unpaid = intervals.reject(&:last)
    days = []
    (start_at.in_time_zone(zone).to_date..end_at.in_time_zone(zone).to_date).each do |day|
      a, b = [start_at, day.in_time_zone(zone)].max, [end_at, (day + 1).in_time_zone(zone)].min
      seconds = [b - a, 0].max.to_i - unpaid.sum { |pause| [[pause[1], b].min - [pause[0], a].max, 0].max.to_i }
      days << { worked_on: day, payable_seconds: seconds } if seconds.positive?
    end
    wage = row.dig('wage', 'hourly_rate') || {}
    cents = wage['amount']
    raise ArgumentError unless cents.nil? || (cents.is_a?(Integer) && cents.between?(0, 2_000_000_000))

    result.merge(state: 'imported', days: days, attributes: { team_member_id: row['team_member_id'], location_id: row['location_id'], timezone: row['timezone'],
      started_at: start_at, ended_at: end_at, payable_seconds: days.sum { |day| day[:payable_seconds] }, unpaid_break_seconds: unpaid.sum { |pause| (pause[1] - pause[0]).to_i }, hourly_rate_cents: cents, currency: wage['currency'] })
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    result.merge(issue: 'Invalid timecard dates, timezone, wage or breaks; no hours counted.')
  end

  def timestamp(value)
    raise ArgumentError unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
    Time.iso8601(value)
  end

  def canonical(value)
    case value
    when Hash then value.sort.to_h.transform_values { |child| canonical(child) }
    when Array then value.map { |child| canonical(child) }
    else value
    end
  end

  def check_overlaps(plan)
    ready = plan.select { |item| item[:state] == 'imported' && !item[:old]&.imported_at && item[:attributes][:payable_seconds].positive? }
    # Existing imported intervals keep their original hours, even if Square changed or removed them.
    ready.each do |item|
      attrs, worker = item.values_at(:attributes, :employee)
      start_at, end_at = attrs.values_at(:started_at, :ended_at)
      next unless start_at && end_at && end_at > start_at
      if SquareTimecard.overlapping(worker.id, start_at, end_at).exists? ||
          ClockShift.where(employee_id: worker.id).where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', end_at, start_at).exists? ||
          local_day_overlap?(worker, start_at, end_at)
        hold(item)
      end
    end
    ready.group_by { |item| item[:employee].id }.each_value do |items|
      active = []
      items.sort_by { |item| item[:attributes][:started_at] }.each do |item|
        start_at, end_at = item[:attributes].values_at(:started_at, :ended_at)
        active.reject! { |prior| prior[:attributes][:ended_at] <= start_at }
        if end_at > start_at
          active.each do |prior|
            hold(prior)
            hold(item)
          end
        end
        active << item if end_at > start_at
      end
    end
  end

  def local_day_overlap?(worker, start_at, end_at)
    worker.timesheet_entries.where(work_type: %w[regular overtime]).where(worked_on: start_at.in_time_zone.to_date..end_at.in_time_zone.to_date).includes(:clock_shift).any? do |entry|
      if entry.clock_shift
        entry.clock_shift.started_at < end_at && (!entry.clock_shift.ended_at || entry.clock_shift.ended_at > start_at)
      else
        entry.worked_on.in_time_zone < end_at && (entry.worked_on + 1).in_time_zone > start_at
      end
    end
  end

  def hold(item)
    item[:state] = 'conflict'
    item[:issue] = 'Overlaps existing Rupert work or another Square timecard; no additional hours counted.'
  end

  def publish(item, now)
    row = item[:row]
    card = item[:old] || SquareTimecard.new(external_id: row['id'])
    previously_imported = card.imported_at.present?
    attrs = { import_status: item[:state], issue: item[:issue], latest_payload: JSON.generate(row), last_seen_at: now,
      source_version: row['version'].is_a?(Integer) ? row['version'] : nil, source_updated_at: (Time.iso8601(row['updated_at']) rescue nil) }
    unless card.imported_at
      attrs.merge!(item[:attributes]).merge!(employee: item[:employee], team_member_id: row['team_member_id'])
      if item[:state] == 'imported'
        attrs.merge!(source_payload: JSON.generate(row), original_digest: item[:digest], imported_at: now)
      end
    end
    card.update!(attrs)
    if item[:state] == 'imported' && !previously_imported
      item[:days].each { |day| card.days.create!(day) }
    end
  end

  def result(plan)
    { source_timecards: plan.size, statuses: plan.group_by { |item| item[:state] }.transform_values(&:size),
      new_timecards: plan.count { |item| item[:state] == 'imported' && !item[:old]&.imported_at },
      new_paid_seconds: plan.select { |item| item[:state] == 'imported' && !item[:old]&.imported_at }.sum { |item| item[:attributes][:payable_seconds] },
      matched_employees: plan.filter_map { |item| item[:employee]&.id }.uniq.size }
  end
end
