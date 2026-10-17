# frozen_string_literal: true

# A server-side shopping cart for a warehouse-sale vendor link. Anonymous
# visitors are keyed by a random token stored in a signed cookie, so the cart
# survives reloads without any login. Prices are always computed server-side
# (never trusted from the browser) via WarehouseShare#sale_price.
class WarehouseCart < ApplicationRecord
  class PaymentLocked < StandardError; end
  class UnavailableItem < StandardError; end
  STATUSES = %w[open checked_out].freeze

  belongs_to :share, class_name: 'WarehouseShare', foreign_key: :share_id
  has_many :items,
    class_name: 'WarehouseCartItem',
    foreign_key: :cart_id,
    dependent: :destroy
  has_many :warehouse_payment_attempts, dependent: :restrict_with_exception

  validates :token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def checked_out?
    status == 'checked_out'
  end

  def add_item!(variant, quantity: 1)
    with_lock do
      ensure_editable!
      variant = ShopifyVariant.warehouse_catalog(tenant_id: tenant_id).find_by(id: variant.id)
      raise UnavailableItem, 'This product is no longer available. Remove it from your cart.' unless variant

      quantity = quantity.to_i.clamp(1, WarehouseCartItem::MAX_QUANTITY)
      item = items.find_or_initialize_by(variant_id: variant.id)
      item.tenant_id = tenant_id
      item.share_id = share_id
      item.sku = variant.sku
      item.title = [variant.product&.title, variant.title].compact.join(' · ')
      item.quantity = (item.quantity.to_i + quantity).clamp(1, WarehouseCartItem::MAX_QUANTITY)
      ensure_available!(item)
      item.assign_price!(share, variant)
      item.save!
      item
    end
  end

  # Update (or remove when <= 0) an existing line, keeping prices in sync with
  # the current quantity.
  def set_quantity!(item_id, quantity)
    with_lock do
      ensure_editable!
      item = items.find(item_id)
      if quantity.to_i <= 0
        item.destroy!
      else
        item.quantity = quantity.to_i.clamp(1, WarehouseCartItem::MAX_QUANTITY)
        variant = item.variant
        raise UnavailableItem, 'This product is no longer available. Remove it from your cart.' unless variant

        ensure_available!(item)
        item.assign_price!(share, variant)
        item.save!
      end
    end
  end

  def remove_item!(item_id)
    with_lock do
      ensure_editable!
      items.find(item_id).destroy!
    end
  end

  def payment_locked?
    checked_out? || warehouse_payment_attempts.unresolved.exists?
  end

  def ensure_editable!
    raise PaymentLocked, 'This cart has a submitted payment. Check its payment status before changing it.' if payment_locked?
  end

  def total_cents
    items.sum(:line_cents)
  end

  def item_count
    items.sum(:quantity)
  end

  def mark_checked_out!
    update!(status: 'checked_out')
  end

  private

  def ensure_available!(item)
    available = item.available_quantity
    raise UnavailableItem, "Only #{available} of this item are available." if item.quantity > available
  end
end
