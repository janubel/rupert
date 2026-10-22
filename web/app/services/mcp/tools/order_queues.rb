# frozen_string_literal: true

require 'set'

module Mcp
  module Tools
    # "What is waiting to be processed?" Every work queue around orders, stock
    # and purchasing, with how old the oldest item is and the page to work it.
    class OrderQueues < Tool
      OPEN_REQUESTS = %w[pending allocated dispatched].freeze

      tool 'order_queues',
        title: 'Order and processing queues',
        description: 'What is waiting to be processed right now, with counts, how old the oldest is and the page to work it: ' \
                     'paid online orders not yet shipped (and the oldest ones with their lines), how many contain a line ' \
                     'with an open low-stock alert when the person may read alerts, orders placed but never paid, stock transfer ' \
                     'and backorder requests (open and overdue), purchase orders awaiting delivery (and late), expense ' \
                     'receipts waiting for review, warehouse stock holds, unresolved card payments at the register and the ' \
                     'warehouse, customer follow-ups due, and reconciliation follow-ups. Read-only.',
        scope: 'reports:read'

      input_schema(
        type: 'object',
        properties: {
          ship_after_hours: { type: 'integer', minimum: 1, maximum: 720, description: 'An unshipped paid online order is late after this many hours. Default 24.' },
          oldest: { type: 'integer', minimum: 0, maximum: 25, description: 'How many of the oldest unshipped orders to list. Default 10.' }
        },
        additionalProperties: false
      )

      def call(args)
        hours = (args['ship_after_hours'] || FulfillmentMonitor::DEFAULT_OVERDUE_HOURS).to_i
        unshipped_queue = unshipped(hours, (args['oldest'] || 10).to_i)
        queues = [unshipped_queue, unpaid, stock_requests, purchase_orders, receipts, holds,
                  payments, customer_follow_ups, reconciliation_follow_ups].compact
        waiting = queues.select { |queue| queue[:count].to_i.positive? }
        text = if waiting.empty?
          'Nothing is waiting in any queue.'
        else
          waiting.map { |queue| "#{queue[:name]}: #{queue[:count]}#{" (#{queue[:late]} late)" if queue[:late].to_i.positive?}" }.join('; ') + '.'
        end
        low_stock_orders = unshipped_queue[:waiting_on_low_stock]
        if low_stock_orders&.positive?
          text += " #{low_stock_orders} waiting paid order#{'s' unless low_stock_orders == 1} " \
                  'contain a line with an open low-stock alert.'
        end
        result(text, { checked_at: Time.current.iso8601, queues: queues, waiting_on_low_stock: low_stock_orders,
                       low_stock_available: user.can?('alerts.read'),
                       oldest_unshipped: unshipped_queue[:oldest_orders] })
      end

      private

      def paths = Rails.application.routes.url_helpers

      def age_hours(time) = time ? ((Time.current - time) / 1.hour).round(1) : nil

      def unshipped(hours, oldest)
        scope = Core::Order.where(channel: 'online', status: 'paid').where.not(fulfillment_status: %w[shipped arrived completed]).where.missing(:fulfillments)
        late = scope.where('occurred_at < ?', hours.hours.ago)
        alerts_available = user.can?('alerts.read')
        alert_skus = alerts_available ? StockAlert.open.where.not(sku: [nil, '']).pluck(:sku).map { |sku| sku.downcase }.to_set : Set.new
        low_stock_order_ids = if alerts_available && alert_skus.any?
          Core::OrderLine.joins(:order).merge(scope).where('LOWER(order_lines.sku) IN (?)', alert_skus.to_a).distinct.pluck(:order_id)
        else
          []
        end
        rows = scope.order(:occurred_at, :id).limit(oldest).map do |order|
          { order: order.display_number, source: order.source, age_hours: age_hours(order.occurred_at),
            gross_cents: order.gross_cents, late: order.occurred_at < hours.hours.ago,
            lines: order.order_lines.limit(100).map do |line|
              row = { name: line.name, sku: line.sku, quantity: line.quantity }
              row[:low_stock] = line.sku.present? ? alert_skus.include?(line.sku.downcase) : nil if alerts_available
              row
            end, path: paths.order_path(order) }
        end
        { name: 'Paid online orders not shipped', count: scope.count, late: late.count, late_after_hours: hours,
          oldest_age_hours: age_hours(scope.minimum(:occurred_at)), oldest_orders: rows,
          waiting_on_low_stock: (low_stock_order_ids.size if alerts_available), path: paths.sales_path(status: 'paid') }
      end

      def unpaid
        scope = Core::Order.where(status: 'placed').where('occurred_at < ?', 24.hours.ago)
        { name: 'Orders placed over a day ago and never paid', count: scope.count, oldest_age_hours: age_hours(scope.minimum(:occurred_at)),
          path: paths.sales_path(status: 'placed') }
      end

      def stock_requests
        return unless user.can?('inventory.read')

        scope = StockRequest.where(status: OPEN_REQUESTS)
        { name: 'Stock requests open', count: scope.count, late: scope.where('due_on < ?', Date.current).count,
          by_kind: scope.group(:request_kind).count, by_status: scope.group(:status).count, path: paths.stock_requests_path }
      end

      def purchase_orders
        return unless user.can?('purchasing.read') || user.can?('inventory.read')

        scope = Purchasing::PurchaseOrder.where(status: 'ordered')
        { name: 'Purchase orders awaiting delivery', count: scope.count, late: scope.where('expected_date < ?', Date.current).count,
          path: paths.purchasing_purchase_orders_path }
      end

      def receipts
        return unless user.can?('finance.read')

        scope = PurchaseReceipt.where(status: 'submitted')
        { name: 'Expense receipts waiting for review', count: scope.count, oldest_age_hours: age_hours(scope.minimum(:created_at)), path: paths.receipts_path }
      end

      def holds
        scope = WarehouseStockHold.where(status: 'held')
        { name: 'Warehouse stock holds', count: scope.count, oldest_age_hours: age_hours(scope.minimum(:created_at)), path: paths.warehouse_path }
      end

      def payments
        register = PosCheckout.where(status: %w[processing unknown]).count
        warehouse = WarehousePaymentAttempt.unresolved.count
        { name: 'Card payments not resolved', count: register + warehouse, register: register, warehouse: warehouse,
          detail: 'A payment the card processor has not confirmed or declined yet; check it before charging again.', path: paths.sales_path }
      end

      def customer_follow_ups
        scope = CustomerFollowUp.due
        { name: 'Customer follow-ups due', count: scope.count, late: scope.where('due_on < ?', Date.current).count }
      end

      def reconciliation_follow_ups
        return unless user.can?('finance.read')

        scope = ReconciliationFollowUp.active
        { name: 'Reconciliation follow-ups', count: scope.count, late: scope.where('due_on < ?', Date.current).count,
          path: paths.reconciliation_follow_ups_path }
      end
    end
  end
end
