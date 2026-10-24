# frozen_string_literal: true

require 'csv'
require 'digest'

class InventoryController < AuthenticatedController
  before_action :authorize_read, only: %i[index comparison workspace movements pdf recommended_skus]

  def index
    workspace
    render(:workspace) unless performed?
  end

  def comparison
    response.headers['Cache-Control'] = 'no-store'
    @comparison = StockComparison.new(shopify_location_id: params[:shopify_location_id],
      ctrax_location_id: params[:ctrax_location_id], query: params[:q], filter: params[:filter])
    if request.format.csv?
      log_export('Stock comparison CSV', comparison_export_details)
      send_data @comparison.csv, filename: "shopify-ctrax-stock-#{Date.current.iso8601}.csv", type: 'text/csv'
    elsif request.format.pdf?
      # Printable copy of the same filtered rows; read-only like the page.
      log_export('Stock comparison PDF', comparison_export_details)
      send_data StockComparisonPdf.new(@comparison).render,
        filename: "shopify-ctrax-stock-#{Time.current.strftime('%Y-%m-%d-%H%M')}.pdf",
        type: 'application/pdf', disposition: 'attachment'
    else
      @view = remembered_view(:stock_comparison_view)
      @pagy, @rows = pagy(:offset, @comparison.rows, limit: @view == 'grid' ? 200 : 50)
      render 'stock_comparisons/index'
    end
  end

  # POST /stock_comparison/pairs { shopify_variant_id, ctrax_location_id, ctrax_record_id, decision: paired|not_same }
  # Saves a person's decision in Rupert only; nothing is written to Shopify or C-Trax.
  def pair
    authorize(:module, :inventory_write?)
    variant = ShopifyVariant.find(params[:shopify_variant_id].to_s)
    snapshot = CtraxStockSnapshot.find_by!(location_id: params[:ctrax_location_id].to_s)
    record = snapshot.records.find { |row| row['id'].to_s == params[:ctrax_record_id].to_s }
    raise ActiveRecord::RecordNotFound unless record

    pair = ProductPair.find_or_initialize_by(shopify_variant_id: variant.id, ctrax_location_id: snapshot.location_id, ctrax_record_id: record['id'].to_s)
    pair.assign_attributes(decision: params[:decision].to_s, decided_by: Current.user, note: params[:note].to_s.strip.first(500).presence,
      shopify_signature: StockIdentityFindings.shopify_signature(variant), ctrax_signature: StockIdentityFindings.ctrax_signature(record))
    if pair.save
      ActivityLogger.log('product_pair_decided', actor: Current.user, details: "#{pair.decision}: shopify=#{variant.id}; ctrax=#{record['id']}")
      redirect_back_to_comparison(notice: pair.paired? ? "Paired #{variant.product&.title} with #{record['name']}." : 'Marked as different products; that suggestion will not come back.')
    else
      redirect_back_to_comparison(alert: pair.errors.full_messages.to_sentence)
    end
  end

  # DELETE /stock_comparison/pairs { shopify_variant_id, ctrax_location_id, ctrax_record_id } — undoes a decision.
  def unpair
    authorize(:module, :inventory_write?)
    pair = ProductPair.find_by!(shopify_variant_id: params[:shopify_variant_id].to_s, ctrax_location_id: params[:ctrax_location_id].to_s,
      ctrax_record_id: params[:ctrax_record_id].to_s)
    pair.destroy!
    ActivityLogger.log('product_pair_undone', actor: Current.user, details: "#{pair.decision}: shopify=#{pair.shopify_variant_id}; ctrax=#{pair.ctrax_record_id}")
    redirect_back_to_comparison(notice: 'Decision undone.')
  end

  def workspace
    response.headers['Cache-Control'] = 'no-store'
    @native_reads = [ShopifyStockSnapshot, CtraxStockSnapshot].flat_map do |model|
      model.select(:id, :location_id, :captured_at).includes(:location).order(captured_at: :desc).limit(20).to_a
    end
    @locations = Location.where(source: %w[shopify square]).order(:source, :name)
    scope = InventoryWorkspace.levels(query: params[:q].to_s.strip, source: params[:source], location_id: params[:location_id])
    scope = case params[:sort]
    when 'low' then scope.order(:available, :id)
    when 'oldest' then scope.order(:updatedAt, :id)
    else scope.order(:source, :locationId, :shopifyVariantId, :squareVariationId, :id)
    end
    if request.format.csv?
      # Read stock in bounded batches, including pools beyond the displayed page.
      # columns= (from the grid's Columns chooser) picks and orders the columns;
      # without it the historical column set is kept.
      log_export('Inventory pool CSV')
      keys = inventory_csv_columns
      csv = CSV.generate do |out|
        out << keys.map { |key| StockHelper::INVENTORY_COLUMNS.fetch(key).last }
        scope.reorder(:id).find_in_batches(batch_size: 500) do |levels|
          InventoryWorkspace.new(levels).rows.each do |row|
            out << keys.map { |key| helpers.inventory_cell(row, key) }.map { |value| value.is_a?(String) ? FinanceHelper.csv_safe(value) : value }
          end
        end
      end
      send_data csv, filename: "inventory-pools-#{Date.current.iso8601}.csv", type: 'text/csv'
    else
      @view = remembered_view(:inventory_view)
      @counts = InventoryCount.where(status: 'pending').count
      @transfers = StockRequest.where(request_kind: 'transfer', status: %w[allocated dispatched]).count
      @backorders = StockRequest.where(request_kind: 'backorder', status: 'pending').count
      @reservations = StockReservation.active_at.count
      # The grid is for scanning many rows at once; the list stays short.
      @pagy, levels = pagy(:offset, scope, limit: @view == 'grid' ? 200 : 50)
      @rows = InventoryWorkspace.new(levels.to_a).rows
    end
  end

  # GET /inventory/movements — the full inventory movement ledger: every
  # quantity change (source, reason, actor, before → after) with filters.
  def movements
    scope = InventoryMovement.includes(:sync_run).order(createdAt: :desc)
    scope = scope.where(source: params[:source]) if params[:source].present?
    if (q = params[:q].to_s.strip).present?
      scope = scope.where(SearchSql.contains_any(%w[sku]), "%#{q}%")
    end
    days = params[:days].to_i
    days = 30 unless (1..365).cover?(days)
    scope = scope.where('"createdAt" >= ?', days.days.ago)
    @pagy, @movements = pagy(:offset, scope, limit: 50)
    @names = movement_names(@movements)
    @sources = InventoryMovement.unscoped.where(tenant_id: Current.tenant_id)
                                .distinct.order(:source).pluck(:source)
  end

  # GET /inventory/recommended_skus — full-catalog Shopify vs Square SKU
  # matching report as CSV (every variant: Shopify SKU, Square SKU, status,
  # and proposed unique SKUs for duplicates). Plan-only: applying requires
  # updating Shopify + Square and re-linking (see ops:sku_remediation_plan).
  def recommended_skus
    send_data SkuMatchReport.csv,
      filename: "sku-report-#{Date.current.iso8601}.csv",
      type: 'text/csv'
  end

  # GET /inventory/pdf — printable snapshot of the current inventory across
  # Shopify and Square, with generated/last-sync timestamps and summary totals.
  # The rendered PDF is cached behind the DataCache version (bumped on every
  # sync / inventory approval), so repeat downloads are instant and the file
  # is regenerated automatically when the mirrored data changes.
  def pdf
    pdf = DataCache.fetch('inventory/pdf') { InventoryPdf.build }
    send_data(
      pdf,
      filename: "inventory-#{Time.current.strftime('%Y-%m-%d-%H%M%S')}.pdf",
      type: 'application/pdf',
      disposition: 'attachment'
    )
  end

  private

  INVENTORY_VIEWS = %w[list grid].freeze
  INVENTORY_CSV_DEFAULT = %w[source location item native_id mirror_quantity mirror_available local_holds warehouse_holds
    promise incoming backorders read_at].freeze

  # List or Grid: the URL wins, then the last choice in this browser.
  def remembered_view(cookie)
    if INVENTORY_VIEWS.include?(params[:view])
      cookies[cookie] = { value: params[:view], expires: 1.year, same_site: :lax, httponly: true }
      params[:view]
    else
      INVENTORY_VIEWS.include?(cookies[cookie]) ? cookies[cookie] : 'list'
    end
  end

  def inventory_csv_columns
    requested = params[:columns].to_s.split(',').map(&:strip) & StockHelper::INVENTORY_COLUMNS.keys
    requested.presence || INVENTORY_CSV_DEFAULT
  end

  def redirect_back_to_comparison(**flash)
    keep = params.permit(:shopify_location_id, :q, :filter, :page).to_h.merge(ctrax_location_id: params[:ctrax_location_id]).compact_blank
    redirect_to stock_comparison_path(keep), **flash
  end

  def authorize_read
    authorize(:module, :inventory_read?)
  end

  def comparison_export_details
    [@comparison.shopify&.location&.name, @comparison.ctrax&.location&.name, "filter=#{@comparison.filter}",
      ("q=#{@comparison.query}" if @comparison.query.present?), "#{@comparison.rows.size} rows"].compact.join(', ')
  end

  # sku => display name + product, resolved once per page so the ledger view
  # doesn't run per-row queries. Square names win for item title (they match
  # the mirrored movement), but Shopify adds the product line.
  def movement_names(movements)
    skus = movements.map(&:sku).compact.uniq
    names = {}
    ShopifyVariant.where(sku: skus).includes(:product).find_each do |variant|
      names[variant.sku] ||= { name: variant.title, product: variant.product&.title }
    end
    SquareVariation.where(sku: skus).find_each do |variation|
      names[variation.sku] ||= { name: variation.name, product: nil }
    end
    names
  end

  # Active locations for the per-location stock columns: Shopify locations
  # first, then Square, alphabetical within each. Shopify and Square are
  # separate locations with independent inventories — each column answers
  # "how many are held THERE", not a comparison.
  def stock_locations
    Location.where(active: true).to_a
            .sort_by { |location| [location.source == 'shopify' ? 0 : 1, location.name.to_s.downcase] }
  end

  # Precompute per-variant stock so the index view doesn't run per-row queries:
  # totals plus per-location breakdowns for both platforms, and the catalog
  # identity status (matched / mismatched / unlinked) from CatalogLinks.
  def variant_stock_map(products)
    size_map = size_family_map
    # Square variations linked to more than one Shopify variant can't be
    # attributed to a single row — flag them so the shared total isn't read as
    # one variant's number (same †-style guard as the PDF report).
    shared_square_variations = SkuLink.linked.group(:squareVariationId).count
                                      .select { |_, n| n > 1 }.keys.to_set

    variants = products.flat_map { |product| product.variants.to_a }
    links_by_variant = SkuLink.where(shopifyVariantId: variants.map(&:id))
                              .linked.includes(:square_variation).index_by(&:shopifyVariantId)
    square_variation_ids = links_by_variant.values.filter_map(&:squareVariationId)

    shopify_by_variant = InventoryLevel.mirrored('shopify')
                                       .where(shopifyVariantId: variants.map(&:id)).group_by(&:shopifyVariantId)
    square_by_variation = InventoryLevel.mirrored('square')
                                        .where(squareVariationId: square_variation_ids).group_by(&:squareVariationId)
    variants_by_product = variants.group_by(&:productId)

    map = {}
    products.each do |product|
      (variants_by_product[product.id] || []).each do |variant|
        link = links_by_variant[variant.id]
        variation = link&.square_variation

        shopify_levels = shopify_by_variant[variant.id] || []
        square_levels = variation ? (square_by_variation[variation.id] || []) : []

        status =
          if link.nil?
            'unlinked'
          elsif link.sku.to_s.downcase == variation.sku.to_s.downcase
            'matched'
          else
            'mismatched'
          end

        map[variant.id] = {
          shopify_qty: shopify_levels.sum(&:quantity),
          shopify_by_location: shopify_levels.index_by(&:locationId).transform_values(&:quantity),
          link: link,
          # nil Square numbers mean "not carried on Square" vs a real 0.
          square_qty: variation ? square_levels.sum(&:quantity) : nil,
          square_by_location: variation ? square_levels.index_by(&:locationId).transform_values(&:quantity) : nil,
          shared: link && shared_square_variations.include?(link.squareVariationId),
          status: status,
          size: size_map[variant.sku.to_s.downcase]
        }
      end
    end
    map
  end

  # sku => size-family membership (root grams, derived target, pending change).
  def size_family_map
    map = {}
    SizeFamily.includes(:members, :size_changes).find_each do |family|
      root = family.base_grams&.to_f
      pending = family.size_changes.select { |change| change.status == 'pending' }
                      .index_by { |change| change.sku.downcase }
      family.members.each do |member|
        map[member.sku.downcase] = {
          family_id: family.id,
          family: family.name,
          grams: member.grams.to_f,
          root: root,
          target: root ? (root / member.grams.to_f).floor : nil,
          pending: pending[member.sku.downcase]
        }
      end
    end
    map
  end
end
