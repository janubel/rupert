# frozen_string_literal: true

# Public checkout for a warehouse-sale cart. Card data is tokenized in the
# browser by Accept.js (hosted fields); only the payment nonce reaches the
# server. On approval a canonical Core::Order is created and the cart is
# checked out.
class WarehouseCheckoutsController < ApplicationController
  layout 'warehouse_sale'
  include WarehousePortal

  skip_before_action :require_login
  skip_before_action :load_last_sync
  before_action :load_share
  before_action :require_cart

  def show
    load_payment_config
  end

  # Browser asks us to validate an Apple Pay session; we relay Apple's answer.
  def apple_pay_session
    return head(:not_found) unless ApplePayMerchantSession.configured?

    session_json = ApplePayMerchantSession.call(
      validation_url: params[:validation_url], domain: request.host, default_name: @share.name
    )
    render json: session_json
  rescue ApplePayMerchantSession::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create
    result = WarehouseCheckoutService.call(
      share: @share,
      cart: current_cart,
      shipping: order_params,
      payment_nonce: params[:payment_nonce],
      data_descriptor: params[:data_descriptor],
      quote_token: params[:checkout_quote]
    )

    if result.success?
      write_order_confirmation(result.order)
      clear_cart_token!
      redirect_to(warehouse_order_path(@share.token, result.order.order_number), notice: 'Order confirmed.')
    else
      load_payment_config
      flash.now[:alert] = result.error
      response.headers['Retry-After'] = WarehouseCheckoutService::ATTEMPT_WINDOW.to_i.to_s if result.rate_limited?
      render(:show, status: result.rate_limited? ? :too_many_requests : :unprocessable_entity)
    end
  end

  private

  def load_payment_config
    @cart = current_cart
    @payment_attempt = @cart.warehouse_payment_attempts.unresolved.order(:id).first
    @checkout_quote = WarehouseCheckoutQuote.issue(@cart) unless @payment_attempt
    @client_key = AuthorizeNetClient.client_key
    @login_id = AuthorizeNetClient.login_id
    @accept_js_url = AuthorizeNetClient.accept_js_url
    @apple_pay = ApplePayMerchantSession.configured? && AuthorizeNetClient.configured?
    @google_pay = AuthorizeNetClient.configured? &&
                  (AuthorizeNetClient.sandbox? || EnvStore.fetch('GOOGLE_PAY_MERCHANT_ID', '').present?)
  end

  def require_cart
    cart = current_cart(include_checked_out: true)
    if cart.checked_out?
      # A committed checkout may have lost its response. The original signed,
      # share-bound cart cookie still proves this browser owns the confirmation.
      order = Core::Order.find_by(source: 'online', source_order_id: "wh-#{cart.id}", channel: 'warehouse')
      return render_404 unless order && %w[paid fulfilled refunded].include?(order.status)

      write_order_confirmation(order)
      clear_cart_token!
      return redirect_to warehouse_order_path(@share.token, order.order_number)
    end
    render_404 if cart.items.none?
  end

  def order_params
    params.permit(
      :shipping_name,
      :shipping_address1,
      :shipping_address2,
      :shipping_city,
      :shipping_province,
      :shipping_zip,
      :shipping_country,
      :shipping_phone,
      :email
    ).to_h.symbolize_keys
  end
end
