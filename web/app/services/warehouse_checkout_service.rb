# frozen_string_literal: true

# Turns a warehouse-sale cart into a paid canonical order. Prices and stock
# are recomputed server-side (never trusted from the browser), payment goes
# through Authorize.net with an Accept.js nonce, and on approval a Core::Order
# with its lines and a card payment are recorded and marked paid.
class WarehouseCheckoutService
  Result = Struct.new(:success?, :order, :error, :rate_limited?, keyword_init: true)
  ATTEMPT_WINDOW = 10.minutes
  CART_ATTEMPT_LIMIT = 5
  SHARE_ATTEMPT_LIMIT = 30

  SHIPPING_FIELDS = %i[
    shipping_name
    shipping_address1
    shipping_address2
    shipping_city
    shipping_province
    shipping_zip
    shipping_country
    shipping_phone
  ].freeze

  class << self
    def call(share:, cart:, shipping: {}, payment_nonce: nil, data_descriptor: nil, quote_token: nil)
      new(
        share: share,
        cart: cart,
        shipping: shipping,
        payment_nonce: payment_nonce,
        data_descriptor: data_descriptor,
        quote_token: quote_token
      ).call
    end
  end

  def initialize(share:, cart:, shipping: {}, payment_nonce: nil, data_descriptor: nil, quote_token: nil)
    @share = share
    @cart = cart
    @shipping = shipping
    @payment_nonce = payment_nonce
    @data_descriptor = data_descriptor
    @quote_token = quote_token
  end

  def call
    @submit_new_attempt = false
    return failure('This cart does not belong to this vendor link.') unless @cart.tenant_id == Current.tenant_id && @share.tenant_id == Current.tenant_id && @cart.share_id == @share.id

    attempt = prepare_attempt
    return attempt if attempt.is_a?(Result)

    submit_payment(attempt) if @submit_new_attempt
    return failure('Payment was declined. You may try a new payment token.') if attempt.reload.status == 'declined'
    return failure('Payment status needs review. Do not submit another payment; contact the store.') unless attempt.status == 'approved'

    complete_approved(attempt)
  rescue ActiveRecord::RecordNotUnique
    failure('This payment token was already submitted. Check its existing payment status.')
  rescue ActiveRecord::RecordInvalid, WarehouseCart::PaymentLocked
    failure('The payment record needs review. No additional charge was submitted; retry to finish an approved payment or contact the store.')
  end

  private

  # The attempt commits before any network I/O. A lost response remains
  # unresolved, and approval survives a failure to create local order records.
  def prepare_attempt
    WarehouseCart.transaction do
      # First statement is a write: serialize the budget across Puma processes
      # in SQLite. No transaction spans the gateway request.
      Tenant.where(id: @cart.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      @cart.lock!
      if @cart.checked_out?
        existing = Core::Order.find_by(tenant_id: @share.tenant_id, source: 'online', source_order_id: order_ref_id)
        return existing ? Result.new(success?: true, order: existing) : failure('This cart has already been checked out.')
      end
      existing = @cart.warehouse_payment_attempts.unresolved.order(:id).first
      return existing if existing
      return failure('Your cart is empty.') if @cart.items.empty?
      return failure('Authorize.net is not configured.') unless AuthorizeNetClient.configured?
      return failure('Payment details are missing or invalid.') unless @payment_nonce.is_a?(String) && @payment_nonce.match?(/\A[!-~]{1,4096}\z/)
      lines = validate_lines
      return failure(lines) if lines.is_a?(String)
      unless WarehouseCheckoutQuote.valid?(@quote_token, @cart)
        return failure('Your cart or prices changed, or checkout expired. Review the updated total and submit again. No payment was submitted.')
      end
      if payment_budget_exhausted?
        return Result.new(success?: false, rate_limited?: true,
          error: 'Too many payment attempts. Wait ten minutes before trying another payment. Approved payments can still be finished.')
      end

      @submit_new_attempt = true
      @gateway_snapshot = AuthorizeNetClient.credential_snapshot
      attempt = @cart.warehouse_payment_attempts.create!(
        tenant_id: @cart.tenant_id, invoice_number: "WH#{SecureRandom.hex(9)}",
        nonce_digest: Digest::SHA256.hexdigest(@payment_nonce.to_s),
        gateway_fingerprint: Digest::SHA256.hexdigest(@gateway_snapshot.to_json),
        amount_cents: @cart.total_cents, shipping_json: @shipping.slice(*SHIPPING_FIELDS).to_json,
        submitted_at: Time.current
      )
      @cart.items.each do |item|
        attempt.warehouse_stock_holds.create!(tenant_id: @cart.tenant_id, warehouse_cart: @cart, variant_id: item.variant_id, quantity: item.quantity)
      end
      attempt
    end
  end

  def payment_budget_exhausted?
    recent = WarehousePaymentAttempt.where(tenant_id: @cart.tenant_id).where('submitted_at >= ?', ATTEMPT_WINDOW.ago)
    return true if recent.where(warehouse_cart_id: @cart.id).limit(CART_ATTEMPT_LIMIT).count >= CART_ATTEMPT_LIMIT

    carts = WarehouseCart.where(tenant_id: @cart.tenant_id, share_id: @share.id).select(:id)
    recent.where(warehouse_cart_id: carts).limit(SHARE_ATTEMPT_LIMIT).count >= SHARE_ATTEMPT_LIMIT
  end

  def submit_payment(attempt)
    charge = AuthorizeNetClient.charge!(amount_cents: attempt.amount_cents, payment_nonce: @payment_nonce,
      data_descriptor: @data_descriptor.presence || 'COMMON.ACCEPT.INAPP.PAYMENT',
      ref_id: order_ref_id, invoice_number: attempt.invoice_number, description: "Warehouse sale · #{@share.name}", credential_snapshot: @gateway_snapshot)
    if charge.approved? && charge.transaction_id.to_s.match?(/\A[A-Za-z0-9_-]{1,64}\z/)
      attempt.update!(status: 'approved', transaction_id: charge.transaction_id, resolved_at: Time.current)
    elsif charge.response_code == '2'
      WarehousePaymentAttempt.transaction do
        attempt.update!(status: 'declined', resolved_at: Time.current)
        attempt.warehouse_stock_holds.held.update_all(status: 'released', release_reason: 'gateway_declined', released_at: Time.current, updated_at: Time.current)
      end
    else
      attempt.update!(status: 'unknown')
      log_payment_review(attempt)
    end
  rescue AuthorizeNetClient::Error, Timeout::Error, SocketError, IOError, SystemCallError, JSON::ParserError, OpenSSL::SSL::SSLError
    attempt.update!(status: 'unknown')
    log_payment_review(attempt)
  end

  def log_payment_review(attempt)
    ActivityLogger.log('warehouse_payment_needs_review', subject: attempt, details: "#{attempt.invoice_number}: #{attempt.status}")
  end

  def complete_approved(attempt)
    @cart.with_lock do
      attempt.reload
      return recover_already_processed! if @cart.checked_out?
      raise WarehouseCart::PaymentLocked unless attempt.status == 'approved' && attempt.amount_cents == @cart.total_cents

      @shipping = attempt.shipping
      lines = @cart.items.map { |item| { item: item } }
      order = create_order(lines, attempt)
      record_success(order, lines, attempt)
      attempt.warehouse_stock_holds.held.update_all(order_id: order.id, updated_at: Time.current)
      @cart.mark_checked_out!
      attempt.update!(status: 'paid')
      Result.new(success?: true, order: order)
    end
  end

  # Revalidate every line against the catalog and current stock, refreshing the
  # stored price snapshot. Returns the validated lines or an error string.
  def validate_lines
    validated = []
    @cart.items.each do |item|
      return 'A cart item is no longer available. Remove it and try again.' unless item.tenant_id == @cart.tenant_id && item.share_id == @share.id

      variant = item.variant
      return "#{item.title.presence || 'Item'} is no longer available." unless variant

      if item.quantity > item.available_quantity
        return "Only #{item.available_quantity} of #{variant.title} are available."
      end

      item.assign_price!(@share, variant)
      item.save!
      validated << { variant: variant, item: item }
    end
    validated
  end

  def create_order(lines, attempt)
    order = Core::Order.new(
      tenant_id: @share.tenant_id,
      source: 'online',
      source_order_id: order_ref_id,
      order_number: attempt.invoice_number,
      channel: 'warehouse',
      currency: 'USD',
      gross_cents: attempt.amount_cents,
      tax_cents: 0,
      line_items: lines.sum { |line| line[:item].quantity },
      occurred_at: Time.current
    )
    SHIPPING_FIELDS.each do |field|
      order.send("#{field}=", @shipping[field]) if @shipping[field].present?
    end
    order.save!
    order
  end

  def record_success(order, lines, charge)
    lines.each do |line|
      item = line[:item]
      Core::OrderLine.create!(
        tenant_id: @share.tenant_id,
        order_id: order.id,
        sku: item.sku.presence,
        source_variant_id: item.variant_id,
        name: item.title,
        quantity: item.quantity,
        unit_cents: item.unit_cents,
        line_cents: item.line_cents
      )
    end
    Core::Payment.create!(
      tenant_id: @share.tenant_id,
      order_id: order.id,
      method: 'card',
      amount_cents: order.gross_cents,
      status: 'completed',
      reference: charge.transaction_id,
      paid_at: Time.current
    )
    order.mark_paid!
  end

  # Correlates local records only; refId is not a gateway idempotency key.
  def order_ref_id
    "wh-#{@cart.id}"
  end

  def recover_already_processed!
    @cart.reload
    return failure('This cart has already been checked out.') unless @cart.checked_out?

    existing = Core::Order.find_by(tenant_id: @share.tenant_id, source: 'online', source_order_id: order_ref_id)
    existing ? Result.new(success?: true, order: existing) : failure('This order was already processed.')
  end

  def failure(error)
    Result.new(success?: false, error: error)
  end
end
