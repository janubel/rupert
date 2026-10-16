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
