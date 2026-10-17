# frozen_string_literal: true

# Public, token-gated warehouse-sale page. The token in the URL is the access
# control — the page is intentionally not linked anywhere in the app.
class WarehouseSalesController < ApplicationController
  layout 'warehouse_sale'
  include WarehousePortal

  skip_before_action :require_login
  skip_before_action :load_last_sync
  before_action :load_share

  def show
    @cart = current_cart
    @variants = ShopifyVariant.warehouse_catalog(tenant_id: @share.tenant_id).includes(:product).to_a
      .sort_by { |variant| [variant.product.title.downcase, variant.title.downcase] }
    @stock_by_variant = InventoryLevel.warehouse_quantities(tenant_id: @share.tenant_id, variant_ids: @variants.map(&:id))
  end
end
