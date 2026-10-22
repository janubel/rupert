# frozen_string_literal: true

module Mcp
  module Tools
    # A read-only snapshot for a short daily business check. Sections retain
    # the permissions and source boundaries of the tools they compose.
    class BusinessPulse < Tool
      tool 'business_pulse',
        title: 'Business pulse',
        description: 'One read-only snapshot for today: gross sales and orders per currency, non-empty waiting queues, ' \
                     'open low-stock alerts, failing source syncs and overdue tasks. Each section includes its Rupert ' \
                     'page. Sections the asking person cannot read are marked unavailable.',
        scope: 'reports:read'

      input_schema(type: 'object', properties: {}, additionalProperties: false)

      def call(_args)
        sales = Metric.new(token: token).call('name' => 'gross_sales', 'period' => 'today', 'compare' => 'none').data
        queues = OrderQueues.new(token: token).call('oldest' => 3).data
        data = {
          date: Date.current.iso8601,
          sales: { gross_sales_by_currency: sales[:values], path: report_path('sales') },
          waiting: {
            queues: queues[:queues].select { |queue| queue[:count].to_i.positive? },
            waiting_on_low_stock: queues[:waiting_on_low_stock],
            paths: queues[:queues].filter_map { |queue| { name: queue[:name], path: queue[:path] } if queue[:count].to_i.positive? && queue[:path].present? }
          },
          alerts: section('list_alerts', { 'status' => 'open', 'per_page' => 3 }, 'alerts', 'rows', 'counts', 'open'),
          sync: section('sync_health', {}, 'operations', 'channels', 'failing'),
          overdue_tasks: section('list_tasks', { 'overdue' => true, 'per_page' => 5 }, nil, 'rows', 'meta', 'total')
        }
        text = [
          "Today (#{data[:date]}): #{sales[:text]}",
          "Waiting queues: #{data[:waiting][:queues].map { |queue| "#{queue[:name]} #{queue[:count]}" }.join('; ').presence || 'none'}.",
          section_summary('Open alerts', data[:alerts]),
          section_summary('Failing syncs', data[:sync]),
          section_summary('Overdue tasks', data[:overdue_tasks])
        ].compact.join(' ')
        result(text, data)
      end

      private

      def section(tool_name, args, report_key, rows_key, counts_key = nil, count_key = nil)
        tool = Registry.find(tool_name)
        return { available: false } unless tool&.available_to?(token)

        outcome = tool.new(token: token).call(args)
        rows = outcome.data[rows_key.to_sym]
        if tool_name == 'sync_health'
          rows = Array(rows).select { |row| row[:failing] }
          count = rows.size
        elsif counts_key
          counts = outcome.data[counts_key.to_sym] || {}
          count = (counts[count_key.to_sym] || counts[count_key.to_s]).to_i
        else
          outcome.data.dig(:meta, :total).to_i
        end
        path = tool_name == 'list_tasks' ? outcome.data[:path] : report_path(report_key)
        { available: true, count: count, rows: Array(rows).first(tool_name == 'list_tasks' ? 5 : 3), path: path }
      end

      def section_summary(label, section)
        return "#{label}: unavailable to this user." unless section[:available]

        "#{label}: #{section[:count]} (#{section[:path]})."
      end

      def report_path(key)
        ListReports::REPORTS.find { |row| row[:key] == key }&.fetch(:path)
      end
    end
  end
end
