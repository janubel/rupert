# frozen_string_literal: true

class CtraxPosController < PointOfSaleController
  PAGE_SIZE = 48

  # The cashier screen is full screen (layouts/pos): no management chrome. A catalog
  # search/category/page change reloads only the product frame, so it renders bare.
  layout -> { turbo_frame_request? ? false : 'pos' }
  before_action :load_store
  rescue_from Pos::Error, with: :invalid_quote

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
    @unfinished_checkouts = PosCheckout.where(location_id: @snapshot&.location_id, status: %w[ready processing unknown declined]).order(updated_at: :desc).limit(10)
    @unfinished_checkouts = @unfinished_checkouts.where(user_id: Current.user.id) unless Current.user.admin? || Current.user.super_admin?
    @pos_setting = PosSetting.find_by(location_id: @snapshot&.location_id)
    @registers = Sales::PosSession.where(location_id: @snapshot&.location_id, status: 'open').order(:opened_at)
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
    records = records.select { |row| row['listed'] != false }
    records, @missing_image_records = records.partition { |row| @images.url(row).present? }
    @categories = records.map { |row| row['category'].presence || 'Uncategorized' }.uniq.sort
    # Sizes of one product, so the item sheet can offer the sibling variants.
    @variant_siblings = records.group_by { |row| variant_group_key(row) }.values.select { |rows| rows.size > 1 }
      .each_with_object({}) { |rows, siblings| rows.each { |row| siblings[row['id']] = rows } }
    # A scanned or typed code that is exactly one item's SKU or barcode (any category).
    @exact_record = exact_code_match(records, @query) if @query.present?
    records = records.select { |row| (row['category'].presence || 'Uncategorized') == @category } if @category.present?
    if @query.present?
      term = @query.downcase
      records = records.select { |row| [row['name'], row['product_name'], row['sku'], row['barcode']].any? { |v| v.to_s.downcase.include?(term) } }
      records = records.each_with_index.sort_by { |row, index| [search_rank(row, term), index] }.map(&:first)
    end
    @total = records.size
    @page_size = PAGE_SIZE
    @page = [params[:page].to_i, 1].max
    @records = records.slice((@page - 1) * PAGE_SIZE, PAGE_SIZE) || []
    @cart_key = "rupert:ctrax:#{Current.tenant_id}:#{Current.user.id}:#{@snapshot&.location_id}:#{@display&.id}"
    @quote ||= @display.draft.deep_symbolize_keys if @display&.demo? && @display.draft['lines'].present?
  end

  def variant_group_key(row)
    row['product_id'].presence || "name:#{(row['product_name'].presence || row['name']).to_s.downcase.strip}"
  end

  def exact_code_match(records, query)
    matches = records.select { |row| [row['sku'], row['barcode']].any? { |code| code.present? && code.to_s.strip.casecmp?(query) } }
    matches.first if matches.size == 1
  end

  # Exact code first, then names that start with the term, then a word that does, then the rest.
  def search_rank(row, term)
    return 0 if [row['sku'], row['barcode']].any? { |code| code.to_s.strip.downcase == term }

    names = [row['product_name'], row['name']].map { |name| name.to_s.downcase }
    return 1 if names.any? { |name| name.start_with?(term) }
    return 2 if names.any? { |name| name.match?(/(?:\A|[^[:alnum:]])#{Regexp.escape(term)}/) }

    3
  end

  def quote_source = 'ctrax'
  def quote_currency = 'USD'
  def quoted_tip(_subtotal) = { type: 'none', percentage: nil, amount: BigDecimal('0') }

  def quote_lines(rows)
    raise QuoteError, 'Refresh C-Trax stock before using this catalog.' unless @snapshot && (@display&.demo? || @snapshot.captured_at >= 60.minutes.ago)

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
    Pos::Quote.decorate!(quote, @snapshot, demo: @display&.demo?)
    return unless @display

    @display.publish!(quote.deep_stringify_keys)
    quote[:display_revision] = @display.cart_revision
  end
end
