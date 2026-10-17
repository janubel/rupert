# frozen_string_literal: true

# Binds a customer's reviewed amount and lines to one cart for a short period.
# Only a digest of line identifiers, quantities and prices enters the token.
class WarehouseCheckoutQuote
  PURPOSE = 'warehouse-checkout-quote'
  LIFETIME = 15.minutes

  def self.issue(cart)
    verifier.generate(payload(cart), purpose: PURPOSE, expires_in: LIFETIME)
  end

  def self.valid?(token, cart)
    return false unless token.is_a?(String) && token.bytesize.between?(1, 4096)

    verifier.verified(token, purpose: PURPOSE) == payload(cart)
  end

  def self.payload(cart)
    lines = cart.items.order(:id).pluck(:id, :variant_id, :quantity, :unit_cents, :line_cents)
    { 'tenant' => cart.tenant_id, 'share' => cart.share_id, 'cart' => cart.id,
      'lines' => Digest::SHA256.hexdigest(lines.to_json) }
  end
  private_class_method :payload

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
  private_class_method :verifier
end
