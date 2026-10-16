# frozen_string_literal: true

module Purchasing
  # Accounts payable: what we owe vendors, from their received/ordered purchase
  # orders minus what we've paid them. Part of the Purchasing context (vendors,
  # POs) feeding the Finance::AccountsController overview.
  class Payables
    class << self
      # Per-vendor AP: received PO value minus payments made.
      def by_vendor
        rows = Purchasing::Vendor.left_joins(:purchase_orders)
                                 .group('vendors.id', 'vendors.name')
                                 .select(
                                   'vendors.id',
                                   'vendors.name',
                                   "COALESCE(SUM(CASE WHEN purchase_orders.status = 'received' THEN
               (SELECT COALESCE(SUM(purchase_order_lines.received_quantity * purchase_order_lines.unit_cost_cents), 0)
                FROM purchase_order_lines
                WHERE purchase_order_lines.purchase_order_id = purchase_orders.id) ELSE 0 END), 0) AS owed_cents",
                                   "COALESCE(SUM(CASE WHEN purchase_orders.status = 'ordered' THEN
               (SELECT COALESCE(SUM(purchase_order_lines.quantity * purchase_order_lines.unit_cost_cents), 0)
                FROM purchase_order_lines
                WHERE purchase_order_lines.purchase_order_id = purchase_orders.id) ELSE 0 END), 0) AS committed_cents"
                                 )

        payments = Finance::VendorPayment.group(:vendor_id).sum(:amount_cents)

        rows.map do |row|
          paid = payments.fetch(row.id, 0)
          {
            vendor: row,
            owed_cents: row.owed_cents.to_i,
            committed_cents: row.committed_cents.to_i,
            paid_cents: paid,
            balance_cents: [row.owed_cents.to_i - paid, 0].max
          }
        end.select { |r| r.values_at(:owed_cents, :committed_cents, :paid_cents).any?(&:positive?) }.sort_by { |r| -r[:balance_cents] }
      end

      def total_cents
        by_vendor.sum { |r| r[:balance_cents] }
      end
    end
  end
end
