# frozen_string_literal: true

class PosCheckoutsController < AuthenticatedController
  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can_use_pos?
    response.headers['Cache-Control'] = 'no-store'
  end
  rescue_from Pos::Error, Ctrax::Client::Error do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end
  def create
    display = PosDisplaySession.find_by!(id: params[:display_id], user_id: Current.user.id)
    if params[:tender] == 'cash' && display.confirmed? && display.draft['tax_verified']
      total = display.draft['subtotal_cents'] + display.draft['tax_cents'] + display.chosen_tip_cents
      raise Pos::Error, 'Cash received is less than the total.' if Pos::Checkout.money(params[:cash_received]) < total
    end
    checkout = Pos::Checkout.prepare!(display: display, tender: params[:tender], register_id: params[:register_id])
    if checkout.tender == 'cash'
      Pos::Checkout.cash!(checkout, received: params[:cash_received])
      PosInventoryJob.perform_later(checkout.id) unless checkout.demo?
    end
    render json: checkout.receipt
  end

  def show
    @checkout = checkout_scope.find(params[:id])
  end

  def cancel
    checkout = checkout_scope.find(params[:id])
    Pos::Checkout.cancel!(checkout)
    display = checkout.pos_display_session
    display.publish!({ 'lines' => [], 'subtotal' => '0', 'currency_code' => 'USD' }) if display.active?
    respond_to do |format|
      format.json { render json: checkout.receipt }
      format.html { redirect_to ctrax_pos_path(location_id: checkout.location_id), notice: 'Unpaid checkout cancelled.' }
    end
  end

  def reconcile
    checkout = checkout_scope.find(params[:id])
    checkout.pos_payment_attempts.where(status: %w[submitting unknown]).each { |attempt| Pos::CardPayment.reconcile!(attempt) }
    redirect_to pos_checkout_path(checkout), notice: 'Gateway status checked; no charge was sent.'
  end

  private

  def checkout_scope
    Current.user.admin? || Current.user.super_admin? ? PosCheckout.all : PosCheckout.where(user_id: Current.user.id)
  end
end
