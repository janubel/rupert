# frozen_string_literal: true

# A line item on a warehouse-sale cart. Unit price is a server-side snapshot
# (list × vendor multiplier − bulk-tier discount) recomputed whenever the
# quantity changes; the checkout service revalidates prices and stock before
# charging.
class WarehouseCartItem < ApplicationRecord
  MAX_QUANTITY = 999

  belongs_to :cart, class_name: 'WarehouseCart', foreign_key: :cart_id

  def variant
    ShopifyVariant.warehouse_catalog(tenant_id: tenant_id).find_by(id: variant_id)
  end

  def available_quantity
    InventoryLevel.warehouse_quantities(tenant_id: tenant_id, variant_ids: [variant_id]).fetch(variant_id, 0)
  end

  # Recompute unit/line prices for the current quantity against the share's
  # tier schedule. Must be called after any quantity change.
  def assign_price!(share, variant)
    qty = quantity.to_i.clamp(1, MAX_QUANTITY)
    self.unit_cents = Money.cents_from_amount(share.sale_price(variant.price, qty)).to_i
    self.line_cents = unit_cents * qty
  end

  def unit_price
    unit_cents.to_f / 100
  end

  def line_price
    line_cents.to_f / 100
  end
end
