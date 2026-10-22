# frozen_string_literal: true

module Mcp
  module Tools
    # "What is waiting to be processed?" Every work queue around orders, stock
    # and purchasing, with how old the oldest item is and the page to work it.
    class OrderQueues < Tool
      OPEN_REQUESTS = %w[pending allocated dispatched].freeze

      tool 'order_queues',
        title: 'Order and processing queues',
        description: 'What is waiting to be processed right now, with counts, how old the oldest is and the page to work it: ' \
                     'paid online orders not yet shipped (and the oldest ones), orders placed but never paid, stock transfer ' \
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
        queues = [unshipped(hours, (args['oldest'] || 10).to_i), unpaid, stock_requests, purchase_orders, receipts, holds,
                  payments, customer_follow_ups, reconciliation_follow_ups].compact
        waiting = queues.select { |queue| queue[:count].to_i.positive? }
        text = if waiting.empty?
          'Nothing is waiting in any queue.'
        else
          waiting.map { |queue| "#{queue[:name]}: #{queue[:count]}#{" (#{queue[:late]} late)" if queue[:late].to_i.positive?}" }.join('; ') + '.'
        end
        result(text, { checked_at: Time.current.iso8601, queues: queues })
      end

      private

      def paths = Rails.application.routes.url_helpers

      def age_hours(time) = time ? ((Time.current - time) / 1.hour).round(1) : nil

      def unshipped(hours, oldest)
        scope = Core::Order.where(channel: 'online', status: 'paid').where.not(fulfillment_status: %w[shipped arrived completed]).where.missing(:fulfillments)
        late = scope.where('occurred_at < ?', hours.hours.ago)
        rows = late.order(:occurred_at, :id).limit(oldest).map do |order|
          { order: order.display_number, source: order.source, age_hours: age_hours(order.occurred_at),
            gross_cents: order.gross_cents, path: paths.order_path(order) }
        end
        { name: 'Paid online orders not shipped', count: scope.count, late: late.count, late_after_hours: hours,
          oldest_age_hours: age_hours(scope.minimum(:occurred_at)), oldest_orders: rows, path: paths.sales_path(status: 'paid') }
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
