# frozen_string_literal: true

class CustomerDisplaysController < ApplicationController
  skip_before_action :require_login
  before_action :load_display

  def show
    render layout: false
  end

  def state
    render json: @display.public_state
  end

  def payment_config
    checkout = @display.current_checkout
    return head(:conflict) unless checkout && checkout.tender == 'card' && %w[ready declined].include?(checkout.status)
    return render(json: { demo: true, total_cents: checkout.total_cents }) if checkout.demo?

    setting = PosSetting.find_by!(location: checkout.location)
    return head(:conflict) unless setting.card_enabled && setting.verified_at && setting.gateway_id == checkout.gateway_id && setting.environment == checkout.environment
    render json: { demo: false, login_id: setting.credentials.fetch('api_login_id'), client_key: setting.public_client_key,
      script_url: setting.environment == 'sandbox' ? 'https://jstest.authorize.net/v3/AcceptUI.js' : 'https://js.authorize.net/v3/AcceptUI.js', total_cents: checkout.total_cents }
  end

  def pay
    checkout = @display.current_checkout
    return head(:conflict) unless checkout && checkout.tender == 'card'
    if checkout.demo?
      checkout.with_lock do
        raise Pos::Error, 'This demo checkout is no longer ready.' unless checkout.paid? || %w[ready declined].include?(checkout.status)
        Pos::Checkout.finalize!(checkout) unless checkout.paid?
      end
    else
      Pos::CardPayment.call(checkout, nonce: params[:payment_nonce])
      PosInventoryJob.perform_later(checkout.id) if checkout.reload.paid?
    end
    render json: checkout.reload.receipt
  rescue Pos::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def tip
    result = @display.choose_tip!(revision: params[:cart_revision], choice: params[:choice], amount: params[:amount])
    case result
    when :confirmed then render json: { confirmed: true, tip_cents: @display.chosen_tip_cents }
    when :changed then render json: { error: 'Your cart changed. Review it and choose again.' }, status: :conflict
    when :expired then render json: { error: 'This customer screen has closed.' }, status: :gone
    else render json: { error: 'Choose no tip, a suggested tip, or a valid custom amount.' }, status: :unprocessable_entity
    end
  end

  private

  def load_display
    token = params[:display_token].to_s
    return head(:not_found) unless token.match?(/\A[A-Za-z0-9_-]{40,60}\z/)

    @display = PosDisplaySession.unscoped.find_by(token_digest: Digest::SHA256.hexdigest(token))
    return head(:gone) unless @display&.active?

    Current.tenant = @display.tenant
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end
