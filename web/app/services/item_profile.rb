# frozen_string_literal: true

# Everything the item page shows about one Shopify variant, from every source Rupert reads: its real name (not
# Shopify's "Default Title"), image, price, cost of goods from the paired C-Trax item, margin per unit, vendor and
# type, stock on each platform and the last 30 days of sales by channel. Read-only; unknown stays unknown.
class ItemProfile
  SALES_DAYS = 30
  PLACEHOLDER_TITLES = ['Default Title', 'Default', 'Regular'].freeze

  Stock = Struct.new(:platform, :place, :quantity, :note, keyword_init: true)
  Sale = Struct.new(:source, :channel, :units, :gross_cents, keyword_init: true)

  attr_reader :variant, :product

  def initialize(variant)
    @variant = variant
    @product = variant.product
  end

  def self.display_name(variant)
    title = variant.title.to_s.strip
    product = variant.product&.title.to_s.strip
    parts = [product.presence, (title unless title.blank? || PLACEHOLDER_TITLES.include?(title) || title == product)]
    parts.compact.join(' · ').presence || title.presence || 'Untitled item'
  end

  def name = self.class.display_name(variant)
  def option = (variant.title unless PLACEHOLDER_TITLES.include?(variant.title.to_s.strip) || variant.title.to_s.strip == product&.title.to_s.strip)
  def image_url = product&.featuredImageUrl.presence
  def price_cents = variant.price && (BigDecimal(variant.price.to_s) * 100).round.to_i
  def vendor = product.try(:vendor).presence
  def product_type = product.try(:productType).presence
  def tags = product&.tags.to_s.split(',').map(&:strip).compact_blank

  # The C-Trax item this variant is paired with: a confirmed pair first, else the one item with the same SKU.
  def ctrax
    return @ctrax if defined?(@ctrax)

    @ctrax = begin
      pair = ProductPair.paired.find_by(shopify_variant_id: variant.id) if defined?(ProductPair)
      snapshots = CtraxStockSnapshot.includes(:location).to_a
      if pair
        snapshot = snapshots.find { |row| row.location_id.to_s == pair.ctrax_location_id }
        record = snapshot&.records&.find { |row| row['id'].to_s == pair.ctrax_record_id }
        { record: record, store: snapshot&.location&.name, how: 'Confirmed pair' } if record
      elsif variant.sku.present?
        found = snapshots.flat_map { |snapshot| snapshot.records.select { |row| row['sku'].to_s.casecmp?(variant.sku.to_s) }.map { |row| [snapshot, row] } }
        { record: found.first.last, store: found.first.first.location&.name, how: 'Same SKU' } if found.one?
      end
    end
  end

  # Cost of goods as entered in C-Trax for the paired item, or nil (with why).
  def cost_cents = ctrax&.dig(:record, 'cost_cents')

  def cost_note
    return 'Not paired with a C-Trax item yet' unless ctrax
    return 'Not entered in C-Trax' unless cost_cents

    "As entered in C-Trax (#{ctrax[:how].downcase})"
  end

  # Price minus cost, per unit before tax; a simple estimate, not accounting profit.
  def margin_cents = (price_cents - cost_cents if price_cents && cost_cents)

  def margin_percent
    return nil unless margin_cents && price_cents&.positive?

    (margin_cents * 100.0 / price_cents).round(1)
  end

  def stock
    rows = variant.levels.includes(:location).map do |level|
      Stock.new(platform: 'Shopify', place: level.location&.name || 'Shopify location',
        quantity: level.sourceQuantity || level.quantity, note: (level.sourceQuantity&.negative? ? 'Oversold' : nil))
    end
    rows << Stock.new(platform: 'Shopify', place: 'All locations', quantity: variant.inventoryQuantity, note: 'Shopify total') if rows.empty?
    link = variant.sku_links.linked.first
    link&.square_variation&.levels&.includes(:location)&.each do |level|
      rows << Stock.new(platform: 'Square', place: level.location&.name || 'Square location', quantity: level.quantity, note: 'Linked variation')
    end
    if (record = ctrax&.dig(:record))
      quantity = record['quantity'] && BigDecimal(record['quantity'].to_s)
      rows << Stock.new(platform: 'C-Trax', place: ctrax[:store] || 'C-Trax store', quantity: quantity&.frac&.zero? ? quantity.to_i : quantity,
        note: record['manage_stock'] ? ctrax[:how] : "#{ctrax[:how]}; stock tracking off")
    end
    rows
  end

  # Units and gross sold in the last 30 days, by source and channel (paid or fulfilled orders).
  def sales
    since = SALES_DAYS.days.ago
    lines = Core::OrderLine.joins(:order).where(orders: { status: DailyRegisterSummary::ELIGIBLE_STATUSES }).where('orders.occurred_at >= ?', since)
    lines = variant.sku.present? ? lines.where('order_lines.source_variant_id = ? OR order_lines.sku = ?', variant.id, variant.sku) : lines.where(source_variant_id: variant.id)
    lines.group('orders.source', 'orders.channel').pluck('orders.source', 'orders.channel', Arel.sql('SUM(order_lines.quantity)'), Arel.sql('SUM(order_lines.line_cents)'))
         .map { |source, channel, units, gross| Sale.new(source: source, channel: channel, units: units.to_i, gross_cents: gross.to_i) }
         .sort_by { |sale| -sale.units }
  rescue ActiveRecord::StatementInvalid
    []
  end
end
