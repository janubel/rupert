# frozen_string_literal: true

module Pos
  class Checkout
    def self.prepare!(display:, tender:, register_id:)
      raise Error, 'Checkout belongs to another workspace.' unless display.tenant_id == Current.tenant_id
      raise Error, 'Choose cash or card.' unless %w[cash card].include?(tender)
      raise Error, 'Customer must confirm their tip choice first.' unless display.active? && display.confirmed?
      existing = display.current_checkout
      return existing if existing && existing.status != 'cancelled' && existing.tender == tender
      raise Error, 'Cancel the current checkout before changing tender.' if existing
      setting_version = nil
      revision = display.cart_revision
      digest = display.draft_digest
      location = display.location
      setting = PosSetting.find_by(location: location)
      if tender == 'card' && setting&.gateway_provider == 'nmi' && !setting.nmi_sandbox?
        raise Error, 'NMI production payments are disabled pending Next Stage confirmation.'
      end
      unless display.demo?
        raise Error, 'Enable this store’s checkout in POS setup first.' unless setting && (tender == 'cash' ? setting.cash_enabled : setting.card_enabled && setting.verified_at)
        setting_version = setting.lock_version
        connection = PosConnection.find_by!(provider: 'ctrax', vendor_approved: true)
        Ctrax::StockSync.call(connection: connection)
      end
      snapshot = CtraxStockSnapshot.find_by!(location: location)
      # Reprice immediately before allocation; never charge a stale browser total.
      quote = reprice(display, snapshot)
      if quote['subtotal_cents'] != display.draft['subtotal_cents'] || quote['tax_cents'] != display.draft['tax_cents'] || quote['lines'].map { |r| r.slice('variant_id', 'quantity', 'unit_price', 'tax_cents') } != display.draft['lines'].map { |r| r.slice('variant_id', 'quantity', 'unit_price', 'tax_cents') }
        display.publish!(quote, expected_revision: revision)
        raise Error, 'Prices or taxes changed. Review the updated cart and confirm the tip again.'
      end
      raise Error, 'Source tax information is incomplete. Refresh the catalog.' unless quote['tax_verified']
      PosCheckout.transaction do
        # First statement is a write: serialize SQLite without a deferred read upgrade.
        Location.where(id: location.id).update_all(active: location.active)
        display.reload
        raise Error, 'Customer confirmation changed. Check the cart again.' unless display.confirmed? && display.cart_revision == revision && display.draft_digest == digest
        existing = display.current_checkout
        return existing if existing && existing.tender == tender
        raise Error, 'A checkout already exists for this cart.' if existing
        if setting_version && setting.reload.lock_version != setting_version
          raise Error, 'POS setup changed. Check this checkout again.'
        end
        register = nil
        unless display.demo?
          register = Sales::PosSession.lock.find_by!(id: register_id, location_id: location.id, status: 'open')
        end
        checkout = PosCheckout.create!(location: location, user: display.user, pos_display_session: display,
          pos_session: register, cart_revision: display.cart_revision, reference: SecureRandom.hex(16), tender: tender,
          demo: display.demo?, lines_json: quote['lines'], subtotal_cents: quote['subtotal_cents'], tax_cents: quote['tax_cents'],
          tip_cents: display.chosen_tip_cents, total_cents: quote['total_before_tip_cents'] + display.chosen_tip_cents,
          gateway_id: tender == 'card' ? setting&.gateway_id : nil, environment: tender == 'card' ? setting&.environment : nil,
          gateway_provider: tender == 'card' ? setting&.gateway_provider || 'authorize_net' : 'authorize_net',
          gateway_fingerprint: tender == 'card' ? setting&.payment_fingerprint : nil)
        unless checkout.demo? || checkout.sandbox_payment?
          records = snapshot.reload.records.index_by { |r| r['id'] }
          checkout.lines.each do |line|
            record = records.fetch(line['variant_id'])
            next unless record['manage_stock']
            quantity = record['quantity'].to_s
            raise Error, 'Stock quantity is unknown or fractional.' unless quantity.match?(/\A-?\d{1,9}\z/)
            held = PosStockAllocation.where(location: location, variant_id: record['id']).where.not(status: 'released')
              .where('applied_at IS NULL OR applied_at >= ?', snapshot.captured_at).sum(:quantity)
            raise Error, "Insufficient stock for #{record['name']}." if quantity.to_i - held < line['quantity']
            PosStockAllocation.create!(location: location, pos_checkout: checkout, variant_id: record['id'], quantity: line['quantity'])
          end
        end
        checkout
      end
    end

    def self.reprice(display, snapshot)
      records = snapshot.records.index_by { |r| r['id'] }
      lines = display.draft.fetch('lines').map do |line|
        record = records[line['variant_id']]
        raise Error, 'A product is unavailable or needs variable-price review.' unless record && record['listed'] != false && !record['variable_price'] && record['price_cents'].is_a?(Integer)
        quantity = line['quantity']
        raise Error, 'Invalid cart quantity.' unless quantity.is_a?(Integer) && quantity.between?(1, 999)
        price = BigDecimal(record['price_cents'].to_s) / 100
        { variant_id: record['id'], sku: record['sku'], title: record['name'], product_title: record['product_name'], thumbnail_url: line['thumbnail_url'], quantity: quantity, unit_price: price.to_s('F'), line_total: (price * quantity).to_s('F') }
      end
      quote = { source: 'ctrax', currency_code: 'USD', preview: display.demo?, lines: lines,
        subtotal: lines.sum { |line| BigDecimal(line[:line_total]) }.to_s('F'), tip_type: 'none', tip_amount: '0.0' }
      Pos::Quote.decorate!(quote, snapshot, demo: display.demo?)
      quote.deep_stringify_keys
    end

    def self.cash!(checkout, received:)
      amount = money(received)
      checkout.with_lock do
        return checkout if checkout.paid?
        raise Error, 'This checkout cannot accept cash.' unless checkout.tender == 'cash' && checkout.status == 'ready'
        raise Error, 'Cash received is less than the total.' if amount < checkout.total_cents
        checkout.assign_attributes(cash_received_cents: amount, change_cents: amount - checkout.total_cents)
        finalize!(checkout)
      end
      checkout
    end

    def self.finalize!(checkout, transaction_id: nil)
      # Caller locks checkout. All durable local sale effects commit atomically.
      return checkout if checkout.paid?
      unless checkout.demo? || checkout.sandbox_payment?
        register = checkout.pos_session
        register.lock!
        raise Error, 'Register closed before payment completed; reconcile this payment.' unless register.status == 'open'
        order = Core::Order.create!(source: 'rupert_pos', source_order_id: checkout.reference,
          order_number: "RP-#{checkout.id}", channel: 'pos', location_id: checkout.location.externalId,
          currency: 'USD', occurred_at: Time.current, gross_cents: checkout.subtotal_cents + checkout.tax_cents,
          tax_cents: checkout.tax_cents, tip_cents: checkout.tip_cents, line_items: checkout.lines.sum { |l| l['quantity'] }, source_lines_complete: true)
        checkout.lines.each do |line|
          order.order_lines.create!(source_line_id: line['variant_id'], source_variant_id: line['variant_id'], sku: line['sku'], name: line['title'], quantity: line['quantity'], unit_cents: (BigDecimal(line['unit_price']) * 100).to_i, line_cents: (BigDecimal(line['line_total']) * 100).to_i)
        end
        order.payments.create!(method: checkout.tender, amount_cents: checkout.total_cents, status: 'completed', paid_at: Time.current, reference: transaction_id || "cash-#{checkout.reference}") if checkout.total_cents.positive?
        order.mark_paid!
        checkout.order = order
        column = checkout.tender == 'cash' ? :cash_sales_cents : :card_sales_cents
        register.update!(column => register.public_send(column).to_i + checkout.total_cents)
        checkout.pos_stock_allocations.update_all(status: 'pending', updated_at: Time.current)
      end
      checkout.update!(status: 'paid', paid_at: Time.current)
      event = checkout.sandbox_payment? ? 'pos_sandbox_checkout_completed' : 'pos_checkout_paid'
      ActivityLogger.log(event, subject: checkout, details: "#{checkout.tender}#{' demo' if checkout.demo?}")
      checkout
    end

    def self.money(value)
      raise Error, 'Enter a nonnegative amount with at most two decimal places.' unless value.to_s.match?(/\A\d{1,6}(?:\.\d{1,2})?\z/)
      (BigDecimal(value.to_s) * 100).to_i
    end

    def self.cancel!(checkout)
      checkout.with_lock do
        raise Error, 'Payment is paid or unresolved. Check the gateway before changing this sale.' unless %w[ready declined].include?(checkout.status)
        checkout.pos_stock_allocations.update_all(status: 'released', updated_at: Time.current)
        checkout.update!(status: 'cancelled')
      end
    end
  end
end
