# frozen_string_literal: true

require 'bigdecimal'

# An image-based cart and server-priced preview. It creates no sale or payment.
class PointOfSaleController < AuthenticatedController
  MAX_LINES = 50
  MAX_QUANTITY = 999
  MAX_UNIT_PRICE = BigDecimal('999999.99')

  class QuoteError < StandardError; end

  before_action :authorize_preview
  before_action :prevent_caching
  rescue_from QuoteError, with: :invalid_quote

  def index
    load_catalog
  end

  def quote
    rows = requested_items
    ids = rows.map { |row| row[:variant_id].to_s }
    raise QuoteError, 'Each cart row must identify a different catalog variant.' unless ids.uniq.size == ids.size

    lines = quote_lines(rows)
    subtotal = lines.sum { |line| BigDecimal(line[:line_total]) }
    tip = quoted_tip(subtotal)
    @quote = {
      source: quote_source, preview: true, currency_code: quote_currency, currency_label: quote_currency || 'Shopify catalog currency',
      lines: lines, subtotal: subtotal.to_s('F'),
      tip_type: tip[:type], tip_percentage: tip[:percentage], tip_amount: tip[:amount].to_s('F'),
      preview_total: (subtotal + tip[:amount]).to_s('F'),
      tax_calculated: false, payment_processed: false, stock_reserved: false, sale_created: false
    }
    publish_display(@quote)
    respond_to do |format|
      format.json { render json: @quote }
      format.html do
        load_catalog
        render :index
      end
    end
  end

  private

  def quote_source = 'shopify'
  def quote_currency = nil
  def publish_display(_quote); end

  def quote_lines(rows)
    ids = rows.map { |row| row[:variant_id].to_s }
    variants = ShopifyVariant.includes(:product).where(id: ids).index_by(&:id)
    raise QuoteError, 'One or more selected items are unavailable to this store.' unless variants.size == ids.size

    duplicates = ShopifyVariant.where(sku: variants.values.map(&:sku).reject(&:blank?))
      .group(:sku).having('COUNT(*) > 1').pluck(:sku)
    rows.map do |row|
      variant = variants.fetch(row[:variant_id].to_s)
      raise QuoteError, 'A selected SKU identifies multiple variants. Resolve the catalog conflict first.' if duplicates.include?(variant.sku)

      quoted_line(variant, row[:quantity])
    end
  end

  def authorize_preview
    return if Current.user.active? && Current.tenant&.status == 'active' &&
      %w[sales.read sales.write inventory.read].all? { |permission| Current.user.can?(permission) }

    respond_to do |format|
      format.json { render json: { error: "You don't have permission to use the POS preview." }, status: :forbidden }
      format.html { redirect_to root_path, alert: "You don't have permission to use the POS preview." }
    end
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
  end

  def load_catalog
    @query = params[:q].to_s.strip.first(200)
    scope = ShopifyVariant.where(catalog_present: [nil, true]).where(productId: ShopifyProduct.active.select(:id)).includes(:product)
    if @query.present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(@query.downcase)}%"
      products = ShopifyProduct.active.where('LOWER(title) LIKE ?', term).select(:id)
      scope = scope.where('LOWER(sku) LIKE ? OR LOWER(title) LIKE ? OR "productId" IN (?)', term, term, products)
    end
    @pagy, @variants = pagy(scope.order(:sku, :id), items: 24)
    @ambiguous_skus = ShopifyVariant.where(sku: @variants.map(&:sku).reject(&:blank?))
      .group(:sku).having('COUNT(*) > 1').pluck(:sku)
    @cart_key = "rupert:pos-preview:#{Current.tenant_id}:#{Current.user.id}"
  end

  def requested_items
    rows = params[:items]
    rows = rows.values if rows.is_a?(ActionController::Parameters)
    unless rows.is_a?(Array) && rows.any? && rows.length <= MAX_LINES
      raise QuoteError, "Choose between 1 and #{MAX_LINES} cart items."
    end
    unless rows.all? { |row| row.is_a?(ActionController::Parameters) && row[:variant_id].is_a?(String) && row[:variant_id].length.between?(1, 255) }
      raise QuoteError, 'Every cart item must identify a catalog variant.'
    end

    rows
  end

  def quoted_line(variant, quantity)
    unless variant.product && variant.product.status == 'ACTIVE' && variant.catalog_present != false && variant.product.catalog_present != false
      raise QuoteError, 'A selected product is inactive or unavailable. Remove it and refresh the catalog.'
    end
    unless quantity.to_s.match?(/\A[1-9]\d{0,2}\z/) && quantity.to_i <= MAX_QUANTITY
      raise QuoteError, "Each quantity must be a whole number between 1 and #{MAX_QUANTITY}."
    end
    price = catalog_price(variant)
    raise QuoteError, 'A selected item has no supported catalog price. Refresh or choose another item.' unless price

    {
      variant_id: variant.id, sku: variant.sku, title: variant.title,
      product_title: variant.product.title, thumbnail_url: safe_thumbnail(variant.product),
      quantity: quantity.to_i, unit_price: price.to_s('F'), line_total: (price * quantity.to_i).to_s('F')
    }
  end

  def catalog_price(variant)
    return if variant.price.nil?

    price = BigDecimal(variant.price.to_s)
    price if price.finite? && price >= 0 && price <= MAX_UNIT_PRICE && price.round(2) == price
  rescue ArgumentError
    nil
  end
  helper_method :catalog_price

  def safe_thumbnail(product)
    url = product.thumbnail_url(width: 240, height: 240)
    return if url.blank?

    uri = URI.parse(url)
    url if %w[http https].include?(uri.scheme) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end
  helper_method :safe_thumbnail

  def quoted_tip(subtotal)
    type = params.fetch(:tip_type, 'none')
    case type
    when 'none'
      { type: 'none', percentage: nil, amount: BigDecimal('0') }
    when 'percentage'
      percentage = tip_decimal(params[:tip_percentage])
      raise QuoteError, 'Choose a tip percentage from 0 to 100.' if percentage > 100

      amount = (subtotal * percentage / 100).round(2, BigDecimal::ROUND_HALF_UP)
      raise QuoteError, 'The preview tip exceeds the supported amount.' if amount > MAX_UNIT_PRICE

      { type: type, percentage: percentage.to_s('F'), amount: amount }
    when 'custom'
      amount = tip_decimal(params[:tip_amount])
      raise QuoteError, 'The custom tip exceeds the supported amount.' if amount > MAX_UNIT_PRICE

      { type: type, percentage: nil, amount: amount.round(2, BigDecimal::ROUND_HALF_UP) }
    else
      raise QuoteError, 'Choose no tip, a percentage, or a custom amount.'
    end
  end

  def tip_decimal(raw)
    unless raw.to_s.match?(/\A\d{1,6}(?:\.\d{1,6})?\z/)
      raise QuoteError, 'Enter a nonnegative tip amount or percentage.'
    end

    BigDecimal(raw.to_s)
  end

  def invalid_quote(error)
    respond_to do |format|
      format.json { render json: { error: error.message }, status: :unprocessable_entity }
      format.html do
        @quote_error = error.message
        load_catalog
        render :index, status: :unprocessable_entity
      end
    end
  end
end
