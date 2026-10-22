# frozen_string_literal: true

# Catalog Links (formerly "Reconcile"): the SKU-level identity audit between
# Shopify variants and Square variations. Read-only by design — Shopify and
# Square are separate locations with independent inventories, so there is no
# quantity plan to apply here. Stock writes happen only through explicit,
# owner-approved flows elsewhere.
class ReconcileController < AuthenticatedController
  before_action :authorize_read

  def index
    response.headers['Cache-Control'] = 'private, no-store'
    @summary = DataCache.fetch('catalog/summary/v2') { CatalogLinks.summary }
    @query = params[:q].to_s.strip.first(150)
    @status = %w[matched mismatched].include?(params[:status]) ? params[:status] : 'all'
    # CatalogLinks.rows is a sorted Struct array. Pagy handles arrays directly,
    # while DataCache avoids rebuilding the 563-row snapshot on every request.
    rows = DataCache.fetch('catalog/rows/v2') { CatalogLinks.rows }
    rows = rows.select { |row| row.status == @status } unless @status == 'all'
    rows = rows.select { |row| [row.sku, row.square_sku, row.shopify_title, row.product_title, row.square_name].join(' ').downcase.include?(@query.downcase) } if @query.present?
    @pagy, @rows = pagy(:offset, rows, limit: 50)
    @size_groups = size_family_groups
  end

  private

  # Each size family rendered as its root plus the sizes that derive from it,
  # so the screen shows which SKUs are derivatives of which root.
  def size_family_groups
    SizeFamilySnapshot.all.map do |snap|
      {
        family: snap.family,
        root: snap.root_grams,
        root_item: snap.root_item,
        members: snap.members,
        pending_count: snap.pending_count
      }
    end
  end

  def authorize_read
    authorize(:module, :reconcile_read?)
  end
end
