# frozen_string_literal: true

module Mcp
  module Tools
    # "How did we do yesterday / last week / this month / last quarter?" One
    # period against the one before it: sales, refunds, top products, and the
    # work around them (tasks, stock alerts, counts, purchase orders, sync
    # failures, and hours and expenses for people who may see them).
    class PeriodReview < Tool
      PERIODS = %w[today yesterday this_week last_week this_pay_week last_pay_week this_month last_month
                   this_quarter last_quarter year_to_date last_year].freeze
      COUNTED = SalesSummary::COUNTED
      SOURCES = SalesSummary::SOURCES

      tool 'period_review',
        title: 'Period review (day, week, month, quarter)',
        description: 'A business review of one period compared with the period before: orders and gross sales by source and ' \
                     'currency with the change, refunds, top products, tasks created and done, stock alerts opened and ' \
                     'resolved, inventory counts, purchase orders received, sync failures, and (when allowed) hours worked ' \
                     'and expenses. Pick a named period (yesterday, last_week, last_month, this_quarter, last_quarter...) ' \
                     'or from/to dates. Amounts are integer cents. C-Trax/SwipeSimple are noted separately, never added. Read-only.',
        scope: 'reports:read'

      input_schema(
        type: 'object',
        properties: {
          period: { type: 'string', enum: PERIODS, description: 'Named period. Default yesterday. Weeks are Monday–Sunday; pay weeks Thursday–Wednesday.' },
          from: DATE_PROPERTY.merge(description: 'Custom first day (use with to instead of period).'),
          to: DATE_PROPERTY.merge(description: 'Custom last day (inclusive).')
        },
        additionalProperties: false
      )

      def call(args)
        from, to, label = window(args)
        prev_from, prev_to = previous(from, to, args['period'])
        current = figures(from, to)
        before = figures(prev_from, prev_to, light: true)
        data = { period: label, from: from.iso8601, to: to.iso8601, compared_with: { from: prev_from.iso8601, to: prev_to.iso8601 },
                 sales: current[:sales], previous_sales: before[:sales], change: change(current[:sales], before[:sales]),
                 refunds: current[:refunds], top_products: current[:top_products], activity: current[:activity],
                 previous_activity: before[:activity], separately_recorded: current[:separate],
                 note: 'Sales are Shopify, Square, Rupert POS and manual orders (paid or fulfilled). Amounts per currency, never added across currencies.' }
        result(summary(label, from, to, data), data)
      end

      private

      def window(args)
        if args['from'].present? || args['to'].present?
          from, to = date_range(args, default_from: Date.current - 6, default_to: Date.current, max_days: 400)
          return [from, to, "#{from.iso8601} to #{to.iso8601}"]
        end

        preset = TimeRangePicker.preset(args['period'].presence || 'yesterday', Date.current)
        raise ToolError.new("Unknown period #{args['period'].to_s.first(30)}.", kind: 'invalid_arguments') unless preset

        [preset.from, [preset.to, Date.current].min, preset.label]
      end

      # The same kind of period just before: the previous month or quarter, else the same number of days.
      def previous(from, to, period)
        case period
        when 'this_month', 'last_month' then [from.prev_month, from.prev_month.end_of_month]
        when 'this_quarter', 'last_quarter' then [from.prev_month(3), from.prev_month(3).end_of_quarter]
        when 'year_to_date' then [from.prev_year, to.prev_year]
        when 'last_year' then [from.prev_year, from.prev_year.end_of_year]
        when 'this_week', 'this_pay_week' then [from - 7, to - 7]
        else
          days = (to - from).to_i + 1
          [from - days, from - 1]
        end
      end

      def range(from, to) = from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day

      def figures(from, to, light: false)
        window = range(from, to)
        orders = Core::Order.where(occurred_at: window, source: SOURCES, status: COUNTED)
        sales = orders.group(:currency).pluck(:currency, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(gross_cents)'))
                      .map { |currency, count, gross, known| { currency: currency, orders: count, gross_cents: known == count ? gross.to_i : nil } }
        sales.each { |line| line[:by_source] = orders.where(currency: line[:currency]).group(:source).sum(:gross_cents).transform_values(&:to_i) }
        out = { sales: sales, activity: activity(from, to, window) }
        return out if light

        out[:refunds] = Core::Refund.joins(:order).where(refunded_at: window).group('orders.currency')
                                    .pluck(Arel.sql('orders.currency'), Arel.sql('COUNT(*)'), Arel.sql('SUM(refunds.amount_cents)'))
                                    .map { |currency, count, cents| { currency: currency, refunds: count, amount_cents: cents.to_i } }
        out[:top_products] = Core::OrderLine.where(order_id: orders.select(:id)).group(:name)
                                            .pluck(:name, Arel.sql('SUM(line_cents)'), Arel.sql('SUM(quantity)'))
                                            .sort_by { |row| -row[1].to_i }.first(5)
                                            .map { |name, cents, units| { name: name, revenue_cents: cents.to_i, units: units.to_i } }
        out[:separate] = separate(from, to)
        out
      end

      def activity(from, to, window)
        data = {
          tasks_created: Projects::Task.where(created_at: window).count,
          tasks_done: Projects::Task.where(completed_at: window).count,
          stock_alerts_opened: StockAlert.where(createdAt: window).count,
          stock_alerts_resolved: StockAlert.where(resolvedAt: window).count,
          inventory_counts: InventoryCount.where(countedAt: window).count,
          purchase_orders_received: Purchasing::PurchaseOrder.where(received_date: from..to).count,
          sync_failures: SyncRun.where(status: 'failed', startedAt: window).count
        }
        if user.can?('timesheets.read')
          data[:hours_worked] = People::TimesheetEntry.joins(:timesheet).where(worked_on: from..to, timesheets: { demo: false }).sum(:hours).to_f.round(1)
        end
        data[:expenses_cents] = Finance::Expense.where(incurred_on: from..to).sum(:amount_cents).to_i if user.can?('finance.read')
        data
      end

      # Recorded by other systems for the same days; may overlap the orders above, so never added to them.
      def separate(from, to)
        swipe = SwipesimpleSalesDay.where(business_date: from..to)
        swipe.exists? ? { swipesimple_net_sales_cents: swipe.sum(:net_sales_cents).to_i, swipesimple_days: swipe.count } : {}
      end

      def change(now, before)
        now.filter_map do |line|
          prior = before.find { |row| row[:currency] == line[:currency] }
          next unless prior && line[:gross_cents] && prior[:gross_cents]&.positive?

          { currency: line[:currency], gross_change_percent: ((line[:gross_cents] - prior[:gross_cents]) * 100.0 / prior[:gross_cents]).round(1),
            orders_change: line[:orders] - prior[:orders] }
        end
      end

      def summary(label, from, to, data)
        sales = data[:sales].map { |line| "#{line[:orders]} orders, #{money(line[:gross_cents])} #{line[:currency]}" }.join('; ').presence || 'no paid orders stored'
        changes = data[:change].map { |row| "#{row[:gross_change_percent].positive? ? '+' : ''}#{row[:gross_change_percent]}% #{row[:currency]}" }.join(', ')
        activity = data[:activity]
        "#{label} (#{from} to #{to}): #{sales}#{" (#{changes} vs the period before)" if changes.present?}. " \
          "Tasks: #{activity[:tasks_created]} created, #{activity[:tasks_done]} done. Stock alerts: #{activity[:stock_alerts_opened]} opened, " \
          "#{activity[:stock_alerts_resolved]} resolved. Sync failures: #{activity[:sync_failures]}."
      end
    end
  end
end
