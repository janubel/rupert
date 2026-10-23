# frozen_string_literal: true

# Maps the Shopify/Square raw payloads into the canonical Core::Order stream
# (orders + order_lines + payments + customers). Idempotent: upserts on
# (tenant_id, source, source_order_id) and replaces line items/payments per
# order on each sync so the canonical store stays in lock-step with the feeds.
#
# Also provides a one-time backfill from the existing LedgerEntry mirror for
# orders that predate the canonical store.
class CanonicalOrderImporter
  SHOPIFY_LINE_ID = %r{\Agid://shopify/LineItem/[1-9][0-9]{0,30}\z}
  SHOPIFY_VARIANT_ID = %r{\Agid://shopify/ProductVariant/[1-9][0-9]{0,30}\z}
  SOURCE_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\z/

  class << self
    def from_shopify!(nodes)
      Array(nodes).each do |node|
        next if node.blank?

        customer = upsert_customer!(
          source: 'shopify',
          external_id: node.dig('customer', 'id'),
          email: node.dig('customer', 'email'),
          first_name: node.dig('customer', 'firstName'),
          last_name: node.dig('customer', 'lastName'),
          phone: node.dig('customer', 'phone')
        )

        Core::Order.transaction do
          Core::Order.upsert(
            order_attrs(node, source: 'shopify', channel: 'online', customer_id: customer&.id),
            unique_by: %i[tenant_id source source_order_id]
          )
          order = Core::Order.find_by(
            tenant_id: Current.tenant_id,
            source: 'shopify',
            source_order_id: node['id']
          )
          replace_order_lines!(order, node['lineItems'])
          replace_payments!(order, shopify_payments(node))
          fulfillments = node['fulfillments']
          fulfillments = fulfillments['nodes'] if fulfillments.is_a?(Hash)
          replace_fulfillments!(order, fulfillments)
          sync_refunds!(order, shopify_refunds(node))
        end
      end
      Array(nodes).length
    end

    def from_square!(orders)
      Array(orders).each do |node|
        next if node.blank?

        customer = if node['customer_id'].present?
          upsert_customer!(source: 'square', external_id: node['customer_id'], email: nil, first_name: nil, last_name: nil)
        else
          # Preserve historical order-linked profiles without inventing a new
          # customer identity for every anonymous sale.
          Core::Customer.find_by(source: 'square', external_id: node['id'])
        end

        Core::Order.transaction do
          Core::Order.upsert(
            order_attrs(node, source: 'square', channel: 'pos', customer_id: customer&.id),
            unique_by: %i[tenant_id source source_order_id]
          )
          order = Core::Order.find_by(
            tenant_id: Current.tenant_id,
            source: 'square',
            source_order_id: node['id']
          )
          replace_order_lines!(order, node['line_items'])
          replace_payments!(order, square_payments(node))
          sync_refunds!(order, square_refunds(node))
        end
      end
      Array(orders).length
    end

    # One-time: hydrate canonical orders from every ledger entry already
    # mirrored (order-level only; line/payment detail is unavailable).
    def backfill_from_ledger!
      count = 0
      LedgerEntry.find_in_batches do |batch|
        batch.each do |entry|
          next if entry.sourceOrderId.blank?

          Core::Order.upsert(
            order_attrs(
              source: entry.source,
              sourceOrderId: entry.sourceOrderId,
              occurredAt: entry.occurredAt,
              grossCents: entry.grossCents,
              status: entry.status,
              lineItems: entry.lineItems,
              orderName: entry.orderName
            ),
            unique_by: %i[tenant_id source source_order_id]
          )
          count += 1
        end
      end
      count
    end

    private

    def upsert_customer!(source:, external_id:, email:, first_name:, last_name:, phone: nil)
      return if external_id.blank?

      existing = Core::Customer.find_by(source: source, external_id: external_id)
      # Order payloads can contain partial or historical customer information.
      return existing if existing&.source_synced_at

      Core::Customer.upsert(
        {
          tenant_id: Current.tenant_id,
          source: source,
          external_id: external_id,
          email: email,
          first_name: first_name,
          last_name: last_name,
          phone: phone,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[tenant_id source external_id]
      )
      Core::Customer.find_by(tenant_id: Current.tenant_id, source: source, external_id: external_id)
    end

    # Replaces all line items for an order with the current payload, keeping
    # the canonical order_lines table in lock-step with the feed. When the
    # payload matches what's already stored, the delete+reinsert churn is
    # skipped (the 15-minute sync re-imports the whole window every cycle).
    def replace_order_lines!(order, line_items)
      nodes = if line_items.is_a?(Hash)
        Array(line_items['nodes'])
      else
        Array(line_items)
              end

      identities = nodes.filter_map { |item| line_identity(item, order.source) if item.is_a?(Hash) }
      duplicates = identities.tally.select { |_id, count| count > 1 }.keys
      rows = nodes.filter_map do |item|
        next unless item.is_a?(Hash) && item.present?

        identity = line_identity(item, order.source)

        {
          source_line_id: duplicates.include?(identity) ? nil : identity,
          source_variant_id: variant_identity(item, order.source),
          sku: item['sku'].presence || item['variation_name'],
          name: item['title'].presence || item['name'] || 'Item',
          quantity: item['quantity'].to_i,
          unit_cents: money_cents(item.dig('originalUnitPriceSet', 'shopMoney')) ||
            money_cents(item.dig('base_price_money')) || 0,
          line_cents: money_cents(item.dig('originalTotalSet', 'shopMoney')) ||
            money_cents(item.dig('total_money')) || 0
        }
      end
      columns = %i[source_line_id source_variant_id sku name quantity unit_cents line_cents]
      return if unchanged_records?(order.order_lines, columns, rows.map { |row| columns.map { |column| row[column] } })

      order.order_lines.delete_all
      rows.each do |attrs|
        order.order_lines.create!(tenant_id: Current.tenant_id, **attrs)
      end
    end

    # Mirrors Shopify fulfillments (with carrier tracking) for an order. Newer
    # fulfillments are upserted; the order's `fulfilled` status is derived from
    # whether any fulfillment exists, keeping the canonical store in lock-step.
    def replace_fulfillments!(order, fulfillments)
      nodes = Array(fulfillments)
      return if nodes.empty? && order.fulfillments.none?

      nodes.each do |node|
        next if node.blank?

        tracking_info = node['trackingInfo']
        tracking = tracking_info.is_a?(Array) ? tracking_info.first : tracking_info
        tracking ||= {}
        Core::Fulfillment.upsert(
          {
            tenant_id: Current.tenant_id,
            order_id: order.id,
            source: 'shopify',
            source_fulfillment_id: node['id'],
            status: normalize_fulfillment_status(node['status']),
            tracking_company: tracking['company'],
            tracking_number: tracking['number'],
            tracking_url: tracking['url'],
            fulfilled_at: parse_time(node['createdAt']) || node['updatedAt'].presence && parse_time(node['updatedAt']),
            created_at: Time.current,
            updated_at: Time.current
          },
          unique_by: %i[source source_fulfillment_id]
        )
      end
      order.fulfillments.reload
      return unless order.fulfillments.any? && order.may_fulfill?

      order.fulfill!
      order.update_columns(updated_at: Time.current)
    end

    # Platform refunds, keyed by the platform refund id in Core::Refund#reference
    # so re-imports update rather than duplicate. Refunds recorded by hand in
    # Rupert (no platform reference) are left alone. When the refunded total
    # reaches the paid total the order moves to the refunded financial status.
    def sync_refunds!(order, refunds)
      refunds.each do |refund|
        next unless refund[:amount_cents].to_i.positive? && refund[:reference].present?

        row = Core::Refund.find_or_initialize_by(order_id: order.id, reference: refund[:reference])
        row.tenant_id ||= Current.tenant_id
        row.assign_attributes(amount_cents: refund[:amount_cents].to_i, method: refund[:method] || 'card',
          refunded_at: refund[:refunded_at] || Time.current, reason: refund[:reason].presence || row.reason)
        row.save! if row.new_record? || row.changed?
      end
      order.refunds.reset
      order.refund! if order.fully_refunded? && order.may_refund?
    end

    def shopify_refunds(node)
      Array(node['refunds']).filter_map do |refund|
        next unless refund.is_a?(Hash) && refund['id'].to_s.match?(%r{\Agid://shopify/Refund/[1-9][0-9]{0,30}\z})

        { reference: refund['id'], amount_cents: money_cents(refund.dig('totalRefundedSet', 'shopMoney')).to_i,
          method: node['paymentGatewayNames'].to_a.any? { |g| g.to_s.downcase.include?('gift') } ? 'gift_card' : 'card',
          refunded_at: parse_time(refund['createdAt']) }
      end
    end

    # Square orders carry a `refunds` array (one per tender refund) and
    # `return_amounts` for returns; the array wins when present.
    def square_refunds(node)
      rows = Array(node['refunds']).filter_map do |refund|
        next unless refund.is_a?(Hash) && refund['id'].present?
        next unless %w[APPROVED COMPLETED].include?(refund['status'].to_s.upcase) || refund['status'].blank?

        { reference: "square-refund:#{refund['id']}", amount_cents: refund.dig('amount_money', 'amount').to_i.abs,
          method: 'card', refunded_at: parse_time(refund['created_at']), reason: refund['reason'] }
      end
      return rows if rows.any?

      returned = node.dig('return_amounts', 'total_money', 'amount').to_i
      return [] unless returned.positive?

      [{ reference: "square-return:#{node['id']}", amount_cents: returned, method: 'card',
         refunded_at: parse_time(node['updated_at']) || parse_time(node['created_at']) }]
    end

    def replace_payments!(order, payments)
      return if unchanged_records?(order.payments, %i[method amount_cents reference],
        payments.map { |p| [p[:method], p[:amount_cents], p[:reference]] })

      order.payments.delete_all
      payments.each do |payment|
        order.payments.create!(
          tenant_id: Current.tenant_id,
          method: payment[:method],
          amount_cents: payment[:amount_cents],
          status: 'completed',
          reference: payment[:reference],
          paid_at: payment[:paid_at] || Time.current
        )
      end
    end

    # True when the stored rows exactly match the payload rows (same order,
    # same columns) — lets the importer skip delete+reinsert on unchanged orders.
    def unchanged_records?(association, columns, expected)
      association.order(:id).pluck(*columns) == expected
    end

    # Shopify returns a paymentGatewayNames array, not itemized tenders; infer
    # a single tender from the order total for tender-type reporting.
    def shopify_payments(node)
      gross = money_cents(node.dig('currentTotalPriceSet', 'shopMoney')).to_i
      return [] if gross.zero?

      gateways = Array(node['paymentGatewayNames'])
      method = if gateways.any? { |g| g.to_s.downcase.include?('gift') }
        'gift_card'
      elsif gateways.any? { |g| g.to_s.downcase.include?('cash') }
        'cash'
      else
        'card'
               end
      [{
        method: method,
        amount_cents: gross,
        reference: node['name'],
        paid_at: parse_time(node['createdAt'])
      }]
    end

    # Square orders carry an itemized `tenders` array.
    def square_payments(node)
      tenders = Array(node['tenders'])
      return [] if tenders.empty?

      tenders.filter_map do |tender|
        amount = (tender.dig('amount_money', 'amount').to_i).abs
        next if amount.zero?

        {
          method: map_square_tender(tender['type']),
          amount_cents: amount,
          reference: tender['id'],
          paid_at: parse_time(tender['created_at']) || parse_time(node['created_at'])
        }
      end
    end

    def map_square_tender(type)
      case type.to_s.upcase
      when 'CASH' then 'cash'
      when 'GIFT_CARD' then 'gift_card'
      when 'CARD', 'SQUARE_ACCOUNT', 'CASH_APP_PAY', 'BUY_NOW_PAY_LATER' then 'card'
      else 'other'
      end
    end

    # Shopify sends the codes typed at checkout; Square has no codes, so its discount names stand in. Kept as typed,
    # trimmed and de-duplicated; matching to an employee's code is case-insensitive at read time.
    def discount_codes(data)
      codes = data['discountCodes'] || Array(data['discounts']).map { |discount| discount['name'] if discount.is_a?(Hash) }
      Array(codes).filter_map { |code| code.to_s.strip.presence&.slice(0, 100) }.uniq.first(20)
    end

    def order_attrs(data = nil, channel: nil, customer_id: nil, source: nil, **kw)
      data = kw if data.nil?
      gross_cents = money_cents(data.dig('currentTotalPriceSet', 'shopMoney')) ||
                    money_cents(data.dig('total_money')) || (data[:grossCents] || data['grossCents']).to_i
      tax_cents = money_cents(data.dig('currentTotalTaxSet', 'shopMoney')) ||
                  money_cents(data.dig('total_tax_money')) || 0

      {
        tenant_id: Current.tenant_id,
        source: source || data[:source] || data['source'] || 'square',
        source_order_id: data[:sourceOrderId] || data['sourceOrderId'] || data['id'],
        source_lines_complete: source == 'shopify' && shopify_inventory_snapshot_complete?(data),
        source_financial_status: data['displayFinancialStatus'] || data['state'],
        order_number: data[:orderName] || data['orderName'] || data['name'] ||
          "SQ-#{data['id'].to_s.slice(0, 12)}",
        channel: channel || data[:channel] || data['channel'],
        customer_id: customer_id,
        discount_codes: discount_codes(data),
        location_id: data['location_id'] || data[:locationId] || data['locationId'],
        occurred_at: parse_time(data['createdAt'] || data['created_at']) ||
          (data[:occurredAt] || data['occurredAt']) || Time.current,
        gross_cents: gross_cents,
        tax_cents: tax_cents,
        status: normalize_status(data['displayFinancialStatus'] || data['state'] ||
          data[:status] || data['status']),
        line_items: data['lineItems']&.dig('nodes')&.length ||
          data['line_items']&.length || (data[:lineItems] || data['lineItems']).to_i,
        currency: data.dig('currentTotalPriceSet', 'shopMoney', 'currencyCode') ||
          data.dig('total_money', 'currency') || data[:currency] || data['currency'] || 'USD',
        shipping_name: address_attr(data, 'name'),
        shipping_address1: address_attr(data, 'address1'),
        shipping_address2: address_attr(data, 'address2'),
        shipping_city: address_attr(data, 'city'),
        shipping_province: address_attr(data, 'province'),
        shipping_zip: address_attr(data, 'zip'),
        shipping_country: address_attr(data, 'country'),
        shipping_phone: address_attr(data, 'phone'),
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    def address_attr(data, key)
      value = data.dig('shippingAddress', key) || data.dig('shipping_address', key)
      value.presence
    end

    # Existing snapshots remain ineligible until an explicit complete source
    # payload is received. Never infer identity, time or refunded quantities.
    def shopify_inventory_snapshot_complete?(data)
      return false unless data['id'].to_s.match?(%r{\Agid://shopify/Order/[1-9][0-9]{0,30}\z})
      return false unless data.key?('cancelledAt') && data['cancelledAt'].nil?
      return false unless verified_source_timestamp?(data['createdAt'])

      connection = data['lineItems']
      return false unless connection.is_a?(Hash) && connection.dig('pageInfo', 'hasNextPage') == false

      nodes = connection['nodes']
      return false unless nodes.is_a?(Array) && nodes.any?
      return false unless nodes.all? do |item|
        item.is_a?(Hash) && line_identity(item, 'shopify') && variant_identity(item, 'shopify') &&
          item['quantity'].is_a?(Integer) && item['quantity'].between?(1, 2_147_483_647) &&
          item['currentQuantity'].is_a?(Integer) && item['currentQuantity'] == item['quantity']
      end

      nodes.pluck('id').uniq.length == nodes.length
    end

    def verified_source_timestamp?(value)
      return false unless value.is_a?(String) && SOURCE_TIMESTAMP.match?(value) && !value.end_with?('-00:00')

      DateTime.iso8601(value).offset.abs <= Rational(14, 24)
    rescue ArgumentError
      false
    end

    def line_identity(item, source)
      value = source == 'shopify' ? item['id'] : item['uid']
      return unless value.is_a?(String) && value.bytesize.between?(1, 255)
      return value if source == 'shopify' && SHOPIFY_LINE_ID.match?(value)

      value if source == 'square' && !value.match?(/[\x00-\x1f\x7f]/)
    end

    def variant_identity(item, source)
      value = if source == 'shopify'
        item['variant'].is_a?(Hash) ? item['variant']['id'] : nil
      else
        item['catalog_object_id']
      end
      return unless value.is_a?(String) && value.bytesize.between?(1, 255)
      return value if source == 'shopify' && SHOPIFY_VARIANT_ID.match?(value)

      value if source == 'square' && !value.match?(/[\x00-\x1f\x7f]/)
    end

    def normalize_fulfillment_status(raw)
      case raw.to_s.downcase
      when 'fulfilled', 'delivered' then 'fulfilled'
      when 'in_transit', 'out_for_delivery' then 'in_transit'
      when 'attempted_delivery', 'failure' then 'delivered'
      else 'pending'
      end
    end

    # Map display statuses from either platform into our aasm state names.
    def normalize_status(raw)
      case raw.to_s.upcase
      when 'PAID', 'COMPLETED', 'CLOSED' then 'paid'
      when 'PARTIALLY_REFUNDED', 'REFUNDED', 'CANCELED', 'CANCELLED' then 'refunded'
      when 'OPEN', 'PLACED', 'PARTIALLY_PAID' then 'placed'
      when 'ANY' then 'placed'
      else 'placed'
      end
    end

    # Converts a platform money payload into cents. Shopify money amounts are
    # dollar strings ("63.60") needing *100; Square money amounts are already
    # integer cents and pass through unchanged.
    def money_cents(hash)
      return if hash.blank?

      amount = hash['amount']
      # Square money payloads arrive as integer cents and must NOT be inflated;
      # Shopify amounts are dollar strings handled by Money.
      amount.is_a?(Numeric) ? amount.to_i : Money.cents_from_amount(amount)
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    rescue ArgumentError
      nil
    end
  end
end
