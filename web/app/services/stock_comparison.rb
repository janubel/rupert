# frozen_string_literal: true

require 'bigdecimal'
require 'csv'

# Two observations of shared stock, never a sum or an inventory adjustment.
class StockComparison
  attr_reader :shopify_snapshots, :ctrax_snapshots, :shopify, :ctrax, :query, :filter

  def initialize(shopify_location_id: nil, ctrax_location_id: nil, query: nil, filter: nil, at: Time.current)
    @at = at
    @query = query.to_s.strip[0, 255]
    @filter = %w[attention unmatched].include?(filter) ? filter : 'all'
    @shopify_snapshots = ShopifyStockSnapshot.includes(:location).order(:location_id).select { |s| s.location&.active }
    @ctrax_snapshots = CtraxStockSnapshot.includes(:location).order(:location_id).select { |s| s.location&.active }
    @shopify = selected(@shopify_snapshots, shopify_location_id, prefer_stock: true)
    @ctrax = selected(@ctrax_snapshots, ctrax_location_id)
  end

  def rows
    @rows ||= build_rows.select do |row|
      (@query.blank? || [row[:label], row[:sku], row[:shopify_id], row[:ctrax_id]].compact.join(' ').downcase.include?(@query.downcase)) &&
        (@filter != 'attention' || row[:issues].any? || row[:difference]&.nonzero?) &&
        (@filter != 'unmatched' || !row[:paired])
    end.sort_by { |row| [row[:issues].any? ? 0 : 1, row[:label].downcase, row[:shopify_id].to_s, row[:ctrax_id].to_s] }
  end

  def summary
    all = build_rows
    { rows: all.size, paired: all.count { |r| r[:paired] }, unknown: all.count { |r| r[:issues].include?('Unknown stock') },
      negative: all.count { |r| r[:issues].include?('Negative stock') }, unpaired: all.count { |r| !r[:paired] } }
  end

  def stale?(snapshot)
    snapshot && snapshot.captured_at < @at - 1.hour
  end

  def catalog_read_at
    ShopifyProduct.maximum(:catalog_read_at)
  end

  def historical_catalog_count
    ShopifyVariant.where(catalog_present: false).count
  end

  def csv
    CSV.generate do |csv|
      csv << ['Item', 'SKU', 'Shopify variant ID', 'C-Trax variant ID', 'Identity', 'Shopify location', 'C-Trax store',
        'Shopify on hand', 'Shopify available', 'Shopify committed', 'C-Trax stock', 'C-Trax minus Shopify on hand',
        'Issues', 'Shopify read time', 'C-Trax read time']
      rows.each do |row|
        values = [row[:label], row[:sku], row[:shopify_id], row[:ctrax_id], row[:identity], shopify&.location&.name, ctrax&.location&.name,
          row[:on_hand], row[:available], row[:committed], row[:ctrax_quantity], row[:difference], row[:issues].join('; '),
          shopify&.captured_at&.iso8601, ctrax&.captured_at&.iso8601]
        csv << values.map do |value|
          if value.is_a?(BigDecimal)
            value.to_s('F').delete_suffix('.0')
          elsif value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/)
            "'#{value}"
          else
            value
          end
        end
      end
    end
  end

  private

  def selected(snapshots, id, prefer_stock: false)
    return snapshots.find { |s| s.location_id == id } || raise(ActiveRecord::RecordNotFound) if id.present?

    choices = prefer_stock ? snapshots.select { |s| s.records.any? } : snapshots
    choices.one? ? choices.first : nil
  end

  def normalized_sku(value)
    value.to_s.strip.downcase.presence
  end

  def native_id(value)
    value.to_s.split('/').last.presence
  end

  def build_rows
    return @all_rows if @all_rows

    catalog = ShopifyVariant.current_catalog.includes(:product).to_a
    variants = catalog.select(&:tracked)
    # Only the catalog epoch that produced this stock snapshot is comparable.
    stocks = shopify ? shopify.records.index_by { |r| r['id'] } : {}
    records = ctrax ? ctrax.records : []
    s_by_sku = catalog.group_by { |v| normalized_sku(v.sku) }
    c_by_sku = records.group_by { |r| normalized_sku(r['sku']) }
    c_by_id = records.select { |r| r['website_variant_id'].present? }.group_by { |r| native_id(r['website_variant_id']) }
    proposals = variants.index_with do |variant|
      direct = c_by_id.fetch(native_id(variant.id), [])
      sku = normalized_sku(variant.sku)
      if direct.one? && direct.first['website_product_id'].present? && native_id(direct.first['website_product_id']) != native_id(variant.productId)
        [nil, 'Conflicting source product ID']
      elsif direct.one?
        [direct.first, 'Source variant ID']
      elsif direct.any?
        [nil, 'Ambiguous source IDs']
      elsif sku && s_by_sku[sku].one? && c_by_sku.fetch(sku, []).one?
        record = c_by_sku[sku].first
        # A conflicting native linkage cannot be replaced by text matching.
        if record['website_variant_id'].present?
          [nil, 'Conflicting source ID']
        elsif record['website_product_id'].present? && native_id(record['website_product_id']) != native_id(variant.productId)
          [nil, 'Conflicting source product ID']
        else
          [record, 'SKU candidate']
        end
      else
        [nil, sku && c_by_sku.fetch(sku, []).any? ? 'Ambiguous SKU' : 'No current match']
      end
    end
    claimed = proposals.values.filter_map(&:first).group_by { |r| r.fetch('id') }
    used = []
    result = variants.map do |variant|
      record, identity = proposals[variant]
      if record && claimed.fetch(record.fetch('id')).size > 1
        record = nil
        identity = 'Shared or conflicting identity'
      end
      used << record.fetch('id') if record
      stock = stocks[variant.id] if shopify && variant.catalog_read_at == shopify.captured_at
      build_row(variant, stock, record, identity)
    end
    result.concat(records.reject { |r| used.include?(r.fetch('id')) }.map { |r| build_row(nil, nil, r, 'No current match') })
    @all_rows = result
  end

  def build_row(variant, stock, record, identity)
    issues = []
    on_hand = stock && stock['on_hand']
    available = stock && stock['available']
    committed = stock && stock['committed']
    quantity = record && record['quantity'] && BigDecimal(record['quantity'].to_s)
    paired = variant && record
    issues << 'Unknown stock' if (variant && on_hand.nil?) || (record && quantity.nil?)
    issues << 'Negative stock' if [on_hand, available, quantity].compact.any?(&:negative?)
    issues << 'Stock tracking off/unverified' if record && !record['manage_stock']
    issues << 'Fractional stock; unit mapping required' if quantity && !quantity.frac.zero?
    issues << 'Stale Shopify read' if variant && stale?(shopify)
    issues << 'Stale C-Trax read' if record && stale?(ctrax)
    issues << identity unless paired
    comparable = paired && on_hand && quantity && record['manage_stock'] && quantity.frac.zero? && !stale?(shopify) && !stale?(ctrax)
    { label: variant ? [variant.product&.title, variant.title].compact.join(' · ') : record['name'].presence || "C-Trax #{record['id']}",
      sku: variant&.sku.presence || record&.dig('sku'), shopify_id: variant&.id, ctrax_id: record&.dig('id'),
      on_hand: on_hand, available: available, committed: committed, ctrax_quantity: quantity,
      difference: comparable ? quantity - on_hand : nil, identity: identity, paired: !!paired, issues: issues,
      listed: record && record.fetch('listed', true) }
  end
end
