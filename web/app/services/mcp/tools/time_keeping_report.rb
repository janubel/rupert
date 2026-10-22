# frozen_string_literal: true

module Mcp
  module Tools
    class TimeKeepingReport < Tool
      tool 'time_keeping_report',
        title: 'Time keeping report',
        description: 'Scheduled versus worked hours for a date range (max 93 days). view=staff gives one row per staff member; ' \
                     'view=daily gives one row per person-day with a plain status (On schedule, No punches, Unscheduled, ' \
                     'Over/Under schedule, Still clocked in, Check clock-out). Worked hours come from Rupert clock and ' \
                     'Square timecards; C-Trax register hours are shown separately and never added. If the token owner ' \
                     'cannot review everyone\'s time, only their own hours are returned. When allowed, sales for the same ' \
                     'dates are included per currency. Defaults to this month. Read-only.',
        scope: 'timesheets:read'

      input_schema(
        type: 'object',
        properties: {
          from: DATE_PROPERTY.merge(description: 'First day (inclusive). Default: first of this month.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive). Default: end of this month.'),
          view: { type: 'string', enum: %w[staff daily], description: 'Default staff.' },
          employee_id: { type: 'integer', minimum: 1, description: 'Only this staff member (People employee ID).' },
          attention_only: { type: 'boolean', description: 'daily view: only person-days that need attention. Default false.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        from, to = date_range(args, default_from: Date.current.beginning_of_month, default_to: Date.current.end_of_month, max_days: 93)
        all_employees = user.can_review_timesheets? || (user.can_manage_accounts? && user.can?('timesheets.read'))
        worker_id = all_employees ? nil : TimeClockService.worker_for(user, include_on_leave: true)&.id
        report = ::TimeKeepingReport.new(from: from, to: to, employee_id: (args['employee_id'] if all_employees),
          all_employees: all_employees, worker_id: worker_id)
        view = args['view'] || 'staff'
        source = view == 'daily' ? report.days : report.staff
        source = source.select(&:attention?) if view == 'daily' && args['attention_only']
        rows, meta = paginate(source, args)
        data = {
          from: from.iso8601, to: to.iso8601, view: view, scope: all_employees ? 'all staff' : 'own hours only',
          totals: report.totals, rows: rows.map { |row| view == 'daily' ? day_row(row) : staff_row(row) }, meta: meta
        }
        data[:sales_same_days] = if user.can?('reports.read')
          sales = ::Metrics.call('gross_sales', from: from.iso8601, to: to.iso8601, compare: 'none')
          { from: from.iso8601, to: to.iso8601, gross_sales_by_currency: sales[:values], available: true }
        else
          { from: from.iso8601, to: to.iso8601, available: false }
        end
        totals = report.totals
        text = "#{from} to #{to} (#{data[:scope]}): #{totals[:people]} people, #{totals[:scheduled]} h scheduled, #{totals[:worked]} h worked, " \
               "#{totals[:ctrax]} h C-Trax observed (not added), #{totals[:attention]} person-days need attention."
        result(text, data)
      rescue ::TimeKeepingReport::Error => e
        raise ToolError.new(e.message, kind: 'invalid_arguments')
      end

      private

      def staff_row(row)
        row.to_h.except(:shifts).merge(scheduled_shifts: row.shifts)
      end

      def day_row(day)
        { date: day.date.iso8601, employee_id: day.employee_id, employee_name: day.employee_name, schedule: day.schedule_label,
          scheduled_hours: day.scheduled_hours, worked_hours: day.worked_hours, ctrax_hours: day.ctrax_hours,
          variance: day.variance, status: day.status, sources: day.sources }
      end
    end
  end
end
