# frozen_string_literal: true

# Presentation for the Stock section: how a pool's figures read on the page.
# Nothing here changes a figure; it only words what InventoryWorkspace and the
# comparison already computed (signed stock stays signed, unknown stays
# unknown, local holds never come from a platform).
module StockHelper
  # Same default as StockAlert#threshold, so "Low" means the same thing on
  # Inventory and Stock alerts.
  LOW_PROMISE = 5

  # Columns of the Inventory grid and of its server CSV, in grid order.
  # key => [heading, csv heading]. The CSV keeps its historical default order
  # (InventoryController::CSV_DEFAULT); the extra keys appear only when asked.
  INVENTORY_COLUMNS = {
    'item' => ['Item', 'Item'], 'native_id' => ['Native ID', 'Native ID'], 'source' => ['Source', 'Source'],
    'location' => ['Location', 'Location'], 'promise' => ['Available to promise', 'Available to promise'],
    'state' => ['Stock state', 'Stock state'], 'mirror_quantity' => ['Mirror quantity', 'Mirror quantity'],
    'mirror_available' => ['Mirror available', 'Mirror available'], 'local_holds' => ['Local holds', 'Local holds'],
    'warehouse_holds' => ['Warehouse holds', 'Warehouse holds'], 'incoming' => ['Incoming', 'Incoming'],
    'backorders' => ['Backorder demand', 'Waiting backorders'], 'read_at' => ['Stock read', 'Read at'],
    'freshness' => ['Freshness', 'Freshness']
  }.freeze

  # [pill class, word] for a pool's available-to-promise, or nil when the
  # figure needs no word. State is never colour alone.
  def stock_promise_state(row)
    return ['pill-rose', 'Check identity'] unless row[:valid_identity]
    return ['pill-taupe', 'Stock unknown'] unless row[:known]
    return ['pill-rose', 'Oversold'] if row[:mirror_quantity].to_i.negative?
    if row[:promise].zero?
      return row[:capacity].to_i.positive? ? ['pill-clay', 'All held'] : ['pill-rose', 'Out of stock']
    end
    return ['pill-clay', 'Low'] if row[:promise] <= LOW_PROMISE

    nil
  end

  def stock_freshness(row)
    row[:fresh] ? ['pill-fern', 'Current'] : ['pill-clay', 'Review']
  end

  # Signed stock with a real minus sign; nil reads "Unknown", never 0.
  def signed_stock(value)
    return 'Unknown' if value.nil?

    value.negative? ? "−#{value.abs}" : value.to_s
  end

  # Item name for a mirrored pool: product and variant, without Shopify's
  # "Default Title" or Square's lone "Regular".
  def stock_item_name(row)
    level = row[:level]
    if level.source == 'shopify' && (variant = level.shopify_variant)
      [variant.product&.title, variant.title].compact_blank.reject { |part| part == 'Default Title' }.uniq.join(' · ').presence || row[:label]
    elsif (variation = level.square_variation)
      [variation.item&.name, variation.name].compact_blank.reject { |part| part == 'Regular' }.uniq.join(' · ').presence || row[:label]
    else
      row[:label]
    end
  end

  def stock_item_sku(row)
    level = row[:level]
    item = level.source == 'shopify' ? level.shopify_variant : level.square_variation
    item&.sku.presence
  end

  # Small product image when the Shopify mirror has one; a letter tile
  # otherwise (Square items carry no image in Rupert).
  def stock_thumbnail(row)
    level = row[:level]
    product = level.source == 'shopify' ? level.shopify_variant&.product : nil
    if (url = product&.thumbnail_url(width: 80, height: 80))
      image_tag(url, alt: '', loading: 'lazy', class: 'stock-thumb')
    else
      tag.span(stock_item_name(row).to_s.strip.first.to_s.upcase.presence || '?', class: 'stock-thumb stock-thumb-empty', aria: { hidden: true })
    end
  end

  # Store comparison quantity: signed as the source sent it, decimals without
  # a trailing ".0", and missing stock never shown as zero.
  def comparison_quantity(value)
    return 'Unknown / unavailable' if value.nil?

    value.is_a?(BigDecimal) ? value.to_s('F').delete_suffix('.0') : value.to_s
  end

  def comparison_sort_value(value)
    value.nil? ? '' : comparison_quantity(value)
  end

  # [pill class or nil, words] for a comparison row's review column.
  def comparison_review(row)
    return ['pill-clay', pluralize(row[:issues].size, 'review flag')] if row[:issues].any?
    return ['pill-clay', 'Counts differ; verify baseline'] if row[:difference]&.nonzero?

    [nil, 'No stock exception in these reads']
  end

  # One grid/CSV cell value for a pool, by INVENTORY_COLUMNS key.
  def inventory_cell(row, key)
    level = row[:level]
    case key
    when 'item' then row[:label]
    when 'native_id' then row[:native_id]
    when 'source' then level.source.capitalize
    when 'location' then level.location&.name
    when 'promise' then row[:promise]
    when 'state' then stock_promise_state(row)&.last || 'Available'
    when 'mirror_quantity' then row[:mirror_quantity]
    when 'mirror_available' then row[:available]
    when 'local_holds' then row[:held]
    when 'warehouse_holds' then row[:warehouse]
    when 'incoming' then row[:incoming]
    when 'backorders' then row[:demand]
    when 'read_at' then level.updatedAt&.iso8601
    when 'freshness' then stock_freshness(row).last
    end
  end
end
