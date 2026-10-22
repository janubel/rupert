# frozen_string_literal: true

module Mcp
  module Tools
    # "What is overdue or at risk for compliance and record keeping?" One list,
    # each item ok / watch / fix with the page that fixes it: the Books check
    # (money records, reviews, approvals, locks, backups), the month and quarter
    # close checklists, payroll and timesheet queues, the Uploads inbox and
    # document retention.
    class ComplianceCheck < Tool
      tool 'compliance_check',
        title: 'Compliance and record keeping check',
        description: 'Lists what is overdue or at risk for compliance and record keeping, each with status (fix, watch, ok) and ' \
                     'the Rupert page that fixes it: Books check items (sales records, payments, refunds, daily reviews and ' \
                     'approvals, period locks, offsite backup, bank lines, ledger balance), the last finished month and quarter ' \
                     'close checklists, timesheets awaiting approval, leave requests, draft pay runs, the Uploads inbox and ' \
                     'Google Drive document retention. Each item is tagged with the sales, payments, deposits, bank, ' \
                     'payroll and records topics it touches. Sales tax filings are not recorded in Rupert. Read-only.',
        scope: 'finance:read'

      input_schema(
        type: 'object',
        properties: {
          days: { type: 'integer', minimum: 7, maximum: 365, description: 'How far back the Books check looks. Default 30.' },
          include_ok: { type: 'boolean', description: 'Also list items that are fine. Default false (only fix and watch).' }
        },
        additionalProperties: false
      )

      def call(args)
        items = books_items(args['days'] || 30) + close_items('monthly') + close_items('quarterly') + people_items + record_items
        items << { area: 'Sales tax', title: 'Sales tax filings', status: 'unknown', path: paths.sales_tax_reports_path,
                   detail: 'Rupert does not record when a sales tax return was filed. The sales tax report shows tax collected per period.' }
        shown = args['include_ok'] ? items : items.reject { |item| item[:status] == 'ok' }
        counts = items.group_by { |item| item[:status] }.transform_values(&:size)
        shown.each { |item| item[:topics] = topics_for(item) }
        data = { checked_at: Time.current.iso8601, counts: counts, items: shown, books_check_path: paths.books_check_path }
        fixes = items.select { |item| item[:status] == 'fix' }
        text = "#{counts['fix'].to_i} to fix, #{counts['watch'].to_i} to watch, #{counts['ok'].to_i} ok." +
               (fixes.any? ? " Fix first: #{fixes.first(4).map { |item| item[:title] }.join('; ')}." : '')
        result(text, data)
      end

      private

      def paths = Rails.application.routes.url_helpers

      # View helpers (BooksDeskHelper builds the checklist links) need the route
      # helpers too; ApplicationController.helpers alone does not have them.
      def helpers
        @helpers ||= Class.new do
          include Rails.application.routes.url_helpers
          include ApplicationController._helpers
        end.new
      end

      def books_items(days)
        safely('Books') do
          BooksCheck.new(window_days: days.to_i).checks.map do |check|
            { area: 'Books', title: check.title, status: check.status.to_s, count: check.count, detail: check.detail.to_s.first(240),
              path: check.path }.compact
          end
        end
      end

      def close_items(kind)
        safely("#{kind.capitalize} close") do
          checklist = PeriodCloseChecklist.latest(kind)
          next [] unless checklist

          checklist.tasks.reject { |task| task.optional }.map do |task|
            status = task.done? ? 'ok' : (task.state == :overdue ? 'fix' : 'watch')
            { area: "#{checklist.kind_label} close", title: "#{checklist.label}: #{task.title}", status: status, detail: task.detail.to_s.first(200),
              path: (helpers.books_desk_task_path(task) if task.link) }.compact
          end
        end
      end

      def people_items
        return [] unless user.can?('timesheets.read')

        safely('People') do
          timesheets = People::Timesheet.non_demo.where(status: 'submitted').count
          leave = People::LeaveRequest.pending.count
          pay_runs = People::PayRun.where(status: 'draft').count
          corrections = ClockCorrection.where(status: 'pending').count
          [
            queue('People', 'Timesheets awaiting approval', timesheets, paths.people_timesheets_path, fix_over: 0),
            queue('People', 'Leave requests waiting', leave, paths.people_leave_requests_path),
            queue('People', 'Draft pay runs', pay_runs, paths.people_pay_runs_path),
            queue('People', 'Clock corrections waiting', corrections, paths.time_clock_path)
          ]
        end
      end

      def record_items
        safely('Records') do
          rows = []
          rows << queue('Records', 'Uploads waiting in the inbox', Upload.open_items.count, paths.uploads_path) if user.can?('uploads.read')
          drive = RetentionDriveConnection.find_by(tenant_id: Current.tenant_id)
          failed = RetentionDriveItem.where(status: 'failed').count
          rows << if drive&.connected?
            { area: 'Records', title: 'Google Drive document retention', status: failed.positive? ? 'fix' : 'ok', count: failed,
              detail: failed.positive? ? "#{failed} files failed to copy." : "Connected#{", last copy #{drive.last_synced_at.to_date}" if drive.last_synced_at}.",
              path: paths.retention_drive_path }
          else
            { area: 'Records', title: 'Google Drive document retention', status: 'watch', detail: 'Not connected: retained originals stay only in Rupert.',
              path: paths.retention_drive_path }
                  end
          rows
        end
      end

      def queue(area, title, count, path, fix_over: nil)
        status = if count.zero? then 'ok'
        elsif fix_over && count > fix_over then 'fix'
        else 'watch'
                 end
        { area: area, title: title, status: status, count: count, path: path }
      end

      def topics_for(item)
        text = "#{item[:area]} #{item[:title]}".downcase
        topics = []
        topics << 'sales' if text.match?(/\bsales?\b|revenue|refund|income/)
        topics << 'payments' if text.match?(/payment|card|tender|processor|payout/)
        topics << 'deposits' if text.match?(/deposit|settlement/)
        topics << 'bank' if text.match?(/bank|statement|reconcil/)
        topics << 'payroll' if text.match?(/payroll|pay run|timesheet|leave request|wages/)
        topics << 'records' if text.match?(/books|close|record|upload|retention|backup|document|receipt|ledger/)
        topics
      end

      # One area failing to load is reported as unknown instead of failing the whole check.
      def safely(area)
        Array(yield)
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { mcp_tool: 'compliance_check', area: area })
        [{ area: area, title: "#{area} could not be checked", status: 'unknown', detail: e.class.name }]
      end
    end
  end
end
