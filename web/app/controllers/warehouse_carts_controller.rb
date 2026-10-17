# frozen_string_literal: true

# Public cart for a warehouse-sale vendor link. Anonymous visitors are keyed
# by a signed cookie holding the cart's random token.
class WarehouseCartsController < ApplicationController
  layout 'warehouse_sale'
  include WarehousePortal

  skip_before_action :require_login
  skip_before_action :load_last_sync
  before_action :load_share
  rescue_from WarehouseCart::PaymentLocked do |error|
    redirect_to warehouse_cart_path(@share.token), alert: error.message
  end

  def show
    @cart = current_cart
  end

  def add_item
    quantity = params[:quantity].to_i.clamp(1, WarehouseCartItem::MAX_QUANTITY)
    variant = ShopifyVariant.find_by(id: params[:variant_id])

    return redirect_to(warehouse_sale_path(@share.token), alert: 'That product is no longer available.') unless variant

    available = InventoryLevel.unscoped.where(shopifyVariantId: variant.id).sum(:quantity)
    if quantity > available
      return redirect_to(warehouse_sale_path(@share.token),
        alert: "Only #{available} of #{variant.title} are available.")
    end

    current_cart.add_item!(variant, quantity: quantity)
    redirect_to(warehouse_cart_path(@share.token), notice: "#{variant.title} added to your cart.")
  end

  def update_item
    current_cart.set_quantity!(params[:item_id], params[:quantity].to_i)
    redirect_to(warehouse_cart_path(@share.token), notice: 'Cart updated.')
  rescue ActiveRecord::RecordNotFound
    redirect_to(warehouse_cart_path(@share.token), alert: 'Item no longer in your cart.')
  end

  def remove_item
    current_cart.remove_item!(params[:item_id])
    redirect_to(warehouse_cart_path(@share.token), notice: 'Item removed.')
  rescue ActiveRecord::RecordNotFound
    redirect_to(warehouse_cart_path(@share.token), alert: 'Item no longer in your cart.')
  end
end
