# frozen_string_literal: true

module Mcp
  module Tools
    class ListReports < Tool
      REPORTS = [
        { key: 'sales', title: 'Sales', path: '/reports/sales', tool: 'sales_summary',
          about: 'Revenue, orders and top products from Shopify, Square and Rupert POS orders.' },
        { key: 'sales_tax', title: 'Sales tax', path: '/reports/sales_tax', tool: 'sales_tax_report',
          about: 'Tax collected per source and store over any dates; estimates are labelled.' },
        { key: 'register_summary', title: 'Register summary', path: '/reports/register_summary', tool: nil,
          about: 'One day of sales, tenders and payment coverage per register.' },
        { key: 'financial', title: 'Financial', path: '/reports/financial', tool: nil, about: 'Revenue, tax, refunds and tender mix.' },
        { key: 'inventory', title: 'Inventory', path: '/reports/inventory', tool: 'inventory_search',
          about: 'Stock valuation, movements and the low-stock pipeline.' },
        { key: 'stock_comparison', title: 'Shopify vs C-Trax stock', path: '/stock_comparison', tool: 'stock_comparison',
          about: 'Two independent stock observations side by side; never summed or adjusted.' },
        { key: 'time_keeping', title: 'Time keeping', path: '/people/time_keeping', tool: 'time_keeping_report',
          about: 'Scheduled versus worked hours per staff member and day.' },
        { key: 'history', title: 'History', path: '/finance/history', tool: 'history_summary',
          about: 'What history Rupert holds per source: dates, record counts, last arrival, empty months and overlaps. Counts, never amounts.' },
        { key: 'operations', title: 'Operations', path: '/reports/operations', tool: nil, about: 'Sync health, reconcile runs, POS cash variance.' },
        { key: 'alerts', title: 'Low-stock alerts', path: '/alerts', tool: 'list_alerts', about: 'Open, resolved and ignored stock alerts.' }
      ].freeze

      tool 'list_reports',
        title: 'List Rupert reports',
        description: 'Lists the reports in Rupert with their in-app page, what each covers, and the MCP tool (if any) that ' \
                     'returns the same data. Use it to decide which tool answers a question. Read-only.',
        scope: 'reports:read'

      def call(_args)
        rows = REPORTS.map do |report|
          tool = report[:tool] && Registry.find(report[:tool])
          report.merge(tool_available: tool ? tool.available_to?(token) : false)
        end
        text = rows.map { |row| "#{row[:title]} — #{row[:about]}#{" Tool: #{row[:tool]}#{' (not allowed for this token)' unless row[:tool_available]}." if row[:tool]}" }.join("\n")
        result(text, { reports: rows })
      end
    end
  end
end
