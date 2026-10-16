# frozen_string_literal: true

class CtraxPosController < PointOfSaleController
  before_action :load_store

  def index
    load_catalog
    render :demo, layout: 'pos_demo' if @display&.demo?
  end

  def image
    return head(:forbidden) unless Current.user.can?('inventory.write')
    raise ActiveRecord::RecordNotFound unless @snapshot && @snapshot.records.any? { |r| r['id'] == params[:variant_id] }

    product = ShopifyProduct.active.find(params[:product_id])
    link = CtraxImageLink.find_or_initialize_by(location_id: @snapshot.location_id, variant_id: params[:variant_id])
    link.update!(shopify_product: product)
    redirect_to ctrax_pos_path(location_id: @snapshot.location_id, q: params[:q]), notice: 'Website image linked. Source stock and SKU were not changed.'
  end

  private

  def load_store
    @snapshots = CtraxStockSnapshot.includes(:location).order(:location_id).to_a
    @snapshot = if params[:location_id].present?
      @snapshots.find { |snapshot| snapshot.location_id == params[:location_id] } || raise(ActiveRecord::RecordNotFound)
    else
      @snapshots.first
    end
    @images = Ctrax::CatalogImages.new(@snapshot&.location)
    @display = PosDisplaySession.find_by(id: params[:display_id], user_id: Current.user.id) if params[:display_id].present?
    if params[:display_id].present? && (!@display || !@display.active? || @display.location_id != @snapshot&.location_id)
      raise ActiveRecord::RecordNotFound
    end
  end

  def load_catalog
    @query = params[:q].to_s.strip.first(200)
    @category = params[:category].to_s.first(500)
    records = @snapshot&.records || []
    @categories = records.map { |row| row['category'].presence || 'Uncategorized' }.uniq.sort
    records = records.select { |row| row['listed'] != false }
    records = records.select { |row| (row['category'].presence || 'Uncategorized') == @category } if @category.present?
    records = records.select { |row| [row['name'], row['product_name'], row['sku'], row['barcode']].any? { |v| v.to_s.downcase.include?(@query.downcase) } } if @query.present?
    @total = records.size
    @page = [params[:page].to_i, 1].max
    @records = records.slice((@page - 1) * 24, 24) || []
    @cart_key = "rupert:ctrax:#{Current.tenant_id}:#{Current.user.id}:#{@snapshot&.location_id}:#{@display&.id}"
    @quote ||= @display.draft.deep_symbolize_keys if @display&.demo? && @display.draft['lines'].present?
  end

  def quote_source = 'ctrax'
  def quote_currency = 'USD'
  def quoted_tip(_subtotal) = { type: 'none', percentage: nil, amount: BigDecimal('0') }

  def quote_lines(rows)
    raise QuoteError, 'Refresh C-Trax stock before using this catalog.' unless @snapshot && @snapshot.captured_at >= 60.minutes.ago

    catalog = @snapshot.records.index_by { |row| row['id'] }
    rows.map do |row|
      record = catalog[row[:variant_id]]
      raise QuoteError, 'A selected variant is unavailable in this C-Trax store.' unless record && record['listed'] != false
      raise QuoteError, 'Variable or missing source prices must be reviewed in C-Trax.' if record['variable_price'] || !record['price_cents'].is_a?(Integer)
      raise QuoteError, 'Choose a whole quantity from 1 to 999.' unless row[:quantity].to_s.match?(/\A[1-9]\d{0,2}\z/)

      price = BigDecimal(record['price_cents'].to_s) / 100
      { variant_id: record['id'], sku: record['sku'], title: record['name'], product_title: record['product_name'] || record['name'],
        thumbnail_url: @images.url(record), quantity: row[:quantity].to_i, unit_price: price.to_s('F'),
        line_total: (price * row[:quantity].to_i).to_s('F') }
    end
  end

  def publish_display(quote)
    @display&.publish!(quote.deep_stringify_keys)
  end
end
