# frozen_string_literal: true

# Shared plumbing for the public, token-gated warehouse-sale pages. The token
# in the URL is the only access control; the tenant is derived from the share
# and anonymous visitors get a server-side cart keyed by a signed cookie.
module WarehousePortal
  extend ActiveSupport::Concern

  private

  def load_share
    @share = WarehouseShare.unscoped.find_by(token: params[:token])
    return render_404 unless @share&.active?

    Current.tenant = @share.tenant
  end

  def current_cart
    @current_cart ||= begin
      cart = WarehouseCart.find_by(token: cart_token) if cart_token
      if cart.nil? || cart.checked_out?
        cart = WarehouseCart.create!(
          share: @share,
          tenant_id: @share.tenant_id,
          token: SecureRandom.alphanumeric(32)
        )
        write_cart_token(cart.token)
      end
      cart
    end
  end

  def clear_cart_token!
    cookies.delete(cart_cookie_key)
  end

  def cart_token
    cookies.signed[cart_cookie_key]
  end

  def write_cart_token(token)
    cookies.signed[cart_cookie_key] = { value: token, expires: 30.days.from_now }
  end

  def cart_cookie_key
    "warehouse_cart_#{@share.token[0, 8]}"
  end

  def render_404
    render(plain: 'Not found', status: :not_found)
  end
end
