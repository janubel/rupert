# frozen_string_literal: true

require 'csv'

module Ctrax
  # Item-level sales summary for stored C-Trax business days. Read-only: it
  # aggregates the normalized order lines already in CtraxDay snapshots, adds
  # current C-Trax stock attributes (SKU, barcode, category) by native variant
  # ID, and checks each sold variant against Rupert's current Shopify catalog
  # with the same exact-evidence matcher as Stock comparison. Nothing is saved,
  # created or sent to any platform.
  #
  # Stored lines carry one native line per unit with its price and tax. There
  # are no line-level discounts, refund lines or quantities in the snapshot:
  # order discounts are never allocated to items, and refunded quantities stay
  # unknown whenever a receipt has a refund. Unknown values stay nil.
  class DailyItems
    EXACT = 0..1
    STATUS_LABELS = { catalog: 'In Rupert catalog', review: 'Name/package candidate · review', missing: 'Not in Rupert catalog' }.freeze

    attr_reader :days

    def initialize(days)
      @days = Array(days)
    end

    def currencies = @days.map(&:currency).uniq
    def single_currency? = currencies.size <= 1

    def items
      @items ||= begin
        rows = {}
        @days.each do |day|
          matches = catalog_matches(day)
          completed_orders(day).each do |order|
            Array(order['lines']).each do |line|
              key = [day.api_origin, day.currency, line['variant_id'], line['name'], line['variant_name']]
              row = rows[key] ||= new_row(day, line)
              record = matches[:records][item_key(line)]
              row[:stores] |= [day.location.name]
              row[:skus] |= [record&.dig('sku')].compact_blank
              row[:barcodes] |= [record&.dig('barcode')].compact_blank
              row[:categories] |= [record&.dig('category')].compact_blank
              row[:stock_record_missing] ||= record.nil? || record['sale_line_only']
              row[:quantity] += 1
              row[:prices] << line['price']
              row[:taxes] << line['tax']
              row[:orders][[day.id, order['id']]] = order
              merge_match(row, matches[:by_key][item_key(line)])
            end
          end
        end
        rows.values.map { |row| finish(row) }.sort_by { |row| [-(row[:gross] || 0), row[:label].downcase] }
      end
    end

    def not_in_catalog
      items.reject { |row| row[:status] == :catalog }
    end

    def categories
      items.group_by { |row| row[:category] }.map do |category, rows|
        { category: category, items: rows.size, quantity: rows.sum { |r| r[:quantity] }, gross: sum_values(rows.map { |r| r[:gross] }),
          receipts: rows.flat_map { |r| r[:order_keys] }.uniq.size }
      end.sort_by { |row| [row[:category].nil? ? 1 : 0, -(row[:gross] || 0), row[:category].to_s] }
    end

    # One tie-out per stored store/day, and a combined one when several days
    # share a currency.
    def tie_outs
      @tie_outs ||= begin
        result = @days.map { |day| tie_out(day.location.name, [day]) }
        result << tie_out('All stores', @days) if @days.many? && single_currency?
        result
      end
    end

    def matched?
      tie_outs.all? { |tie| tie[:matched] }
    end

    def csv
      CSV.generate do |csv|
        csv << ['Business date', 'Stores', 'Currency', 'C-Trax variant ID', 'Product', 'Variant', 'SKU (current C-Trax stock)', 'Barcode (current C-Trax stock)',
          'Category (current C-Trax stock)', 'Quantity (units)', 'Receipts', 'Gross line amount (minor units)', 'Line tax (minor units)',
          'Discounts (minor units)', 'Receipts with discounts', 'Receipts with refunds', 'Refunded quantity (units)', 'Refunded amount (minor units)',
          'Net (minor units)', 'Rupert catalog', 'Match evidence', 'Rupert catalog item', 'Shopify variant ID']
        dates = @days.map(&:business_date).uniq.join(' ')
        items.each do |row|
          values = [dates, row[:stores].join('; '), row[:currency], row[:variant_id], row[:name], row[:variant_name], row[:sku], row[:barcode], row[:category],
            row[:quantity], row[:receipts], row[:gross], row[:tax], row[:discount], row[:discounted_receipts], row[:refund_receipts],
            row[:refunded_quantity], row[:refunded_amount], row[:net], STATUS_LABELS.fetch(row[:status]),
            [row[:identity], *row[:evidence], *row[:issues]].compact.join('; '), row[:catalog_label], row[:catalog_id]]
          csv << values.map { |value| value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value }
        end
      end
    end

    private

    def completed_orders(day)
      Reconciliation.new(day).orders
    end

    def item_key(line)
      line['variant_id'].presence || "sale-line:#{[line['name'], line['variant_name']].join(' · ')}"
    end

    def new_row(day, line)
      { currency: day.currency, variant_id: line['variant_id'], name: line['name'], variant_name: line['variant_name'],
        stores: [], skus: [], barcodes: [], categories: [], quantity: 0, prices: [], taxes: [], orders: {}, match: nil }
    end

    def merge_match(row, match)
      return unless match
      return if row[:match] && rank(row[:match]) <= rank(match)

      row[:match] = match
    end

    def rank(match)
      match[:variant] ? match[:priority] : 9
    end

    def finish(row)
      orders = row[:orders].values
      discounts = orders.map { |o| o['discount'] }
      refund_counts = orders.map { |o| o['refund_count'] }
      gross = sum_values(row[:prices])
      # An order discount cannot be allocated to its lines; it is known to be
      # zero for an item only when every receipt containing it had none.
      discount = discounts.all? { |value| value&.zero? } ? 0 : nil
      refunds_known = refund_counts.none?(&:nil?) && refund_counts.all?(&:zero?)
      refunded_quantity = refunds_known ? 0 : nil
      refunded_amount = refunds_known ? 0 : nil
      match = row.delete(:match) || {}
      status = :missing
      status = EXACT.cover?(match[:priority]) ? :catalog : :review if match[:variant]
      row.merge(
        label: [row[:name], row[:variant_name]].compact_blank.join(' · ').presence || "C-Trax #{row[:variant_id]}", stores: row[:stores].sort,
        sku: row[:skus].join('; ').presence, barcode: row[:barcodes].join('; ').presence, category: row[:categories].join('; ').presence,
        gross: gross, tax: sum_values(row[:taxes]), discount: discount,
        discounted_receipts: discounts.none?(&:nil?) ? discounts.count(&:nonzero?) : nil,
        refund_receipts: refund_counts.none?(&:nil?) ? refund_counts.count(&:positive?) : nil,
        refunded_quantity: refunded_quantity, refunded_amount: refunded_amount,
        net: [gross, discount, refunded_amount].any?(&:nil?) ? nil : gross - discount - refunded_amount,
        receipts: orders.size, order_keys: row[:orders].keys, status: status, identity: match[:identity],
        evidence: match[:evidence] || [], issues: match[:issues] || [],
        catalog_label: match[:variant] && [match[:variant].product&.title, match[:variant].title].compact.join(' · '),
        catalog_id: match[:variant]&.id
      ).except(:prices, :taxes, :orders, :skus, :barcodes, :categories)
    end

    # Exact evidence first (native website IDs, SKU, barcode), then an exact
    # normalized name + explicit package as a review candidate, as in
    # StockComparison. Sold variants absent from the current stock read are
    # matched by their sale-line name only; their SKU/barcode stay unknown.
    def catalog_matches(day)
      snapshot = CtraxStockSnapshot.find_by(location_id: day.location_id)
      snapshot = nil unless snapshot && snapshot.api_origin == day.api_origin && snapshot.store_id.to_s == day.store_id.to_s
      records = snapshot ? snapshot.records : []
      by_id = records.index_by { |record| record['id'].to_s }
      sold = completed_orders(day).flat_map { |order| Array(order['lines']) }.index_by { |line| item_key(line) }
      lookup = {}
      extra = []
      sold.each do |key, line|
        record = line['variant_id'].present? && by_id[line['variant_id'].to_s]
        unless record
          record = { 'id' => key, 'name' => [line['name'], line['variant_name']].compact_blank.join(' '), 'product_name' => line['name'],
                     'sale_line_only' => true }
          extra << record
        end
        lookup[key] = record
      end
      all_records = records + extra
      matcher = StockIdentityMatcher.new(catalog: catalog, records: all_records, historical: historical)
      claimed = {}
      catalog.each do |variant|
        match = matcher.matches.fetch(variant.id)
        claimed[match.record.fetch('id')] = { variant: variant, priority: match.priority, identity: match.identity, evidence: match.evidence, issues: match.issues } if match.record
      end
      by_key = lookup.to_h do |key, record|
        found = claimed[record.fetch('id')]
        found ||= { identity: matcher.unmatched(record)[:identity], evidence: [], issues: [] }
        found = found.merge(issues: found[:issues] + ['Not in the current C-Trax stock read; SKU/barcode unknown']) if record['sale_line_only']
        [key, found]
      end
      { records: lookup, by_key: by_key }
    end

    def catalog
      @catalog ||= ShopifyVariant.current_catalog.includes(:product).to_a
    end

    def historical
      @historical ||= ShopifyVariant.where.not(id: catalog.map(&:id)).includes(:product).to_a
    end

    def sum_values(values)
      values.any?(&:nil?) ? nil : values.sum
    end

    def tie_out(label, days)
      orders = days.flat_map { |day| completed_orders(day) }
      excluded = days.sum { |day| day.orders.size } - orders.size
      lines = orders.flat_map { |order| Array(order['lines']) }
      order_sum = ->(key) { sum_values(orders.map { |order| order[key] }) }
      line_price = sum_values(lines.map { |line| line['price'] })
      line_tax = sum_values(lines.map { |line| line['tax'] })
      discount = order_sum.call('discount')
      shipping = order_sum.call('shipping_amount')
      shipping_tax = order_sum.call('shipping_tax_amount')
      parts = [line_price, discount, line_tax, shipping, shipping_tax]
      explained = parts.any?(&:nil?) ? nil : line_price - discount + line_tax + shipping + shipping_tax
      payments = orders.flat_map { |order| Array(order['payments']) }.select { |p| p['status'] == 'completed' && !p['deleted'] }
      rows = [
        { label: 'Item line amounts vs order subtotals', items: line_price, orders: order_sum.call('subtotal') },
        { label: 'Item line tax vs order tax', items: line_tax, orders: order_sum.call('tax') },
        { label: 'Items − discounts + tax + shipping vs order totals', items: explained, orders: order_sum.call('total') }
      ].map { |row| row.merge(delta: row[:items].nil? || row[:orders].nil? ? nil : row[:items] - row[:orders]) }
      refund_controls = days.map { |day| day.controls['refunds_totals_sum'] }
      { label: label, currency: days.first&.currency, rows: rows, matched: rows.all? { |row| row[:delta] == 0 },
        receipts: orders.size, units: lines.size, excluded: excluded,
        components: [['Item line amounts', line_price], ['Order discounts (not allocated to items)', discount], ['Item line tax', line_tax],
                     ['Shipping', shipping], ['Shipping tax', shipping_tax]],
        outside: [['Tips (not in order totals)', order_sum.call('tip')],
                  ['Card surcharges (not in order totals)', sum_values(payments.map { |p| p['surcharge_amount'] })],
                  ['Source report refunds (not itemized)', sum_values(refund_controls)]] }
    end
  end
end
