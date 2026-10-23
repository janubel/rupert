# frozen_string_literal: true

# Presentation helpers for the full-screen cashier (ctrax_pos). Nothing here prices,
# reserves or charges: the cart is quoted on the server and checkout rules live in
# Pos::Checkout. These only describe catalog rows and tender readiness to the cashier.
module PosScreenHelper
  LOW_STOCK = 5

  def pos_product_title(record)
    record['product_name'].presence || record['name'].to_s
  end

  # The size/variant part of a C-Trax full name ("Tea Tin 30ml" under "Tea Tin" → "30ml").
  def pos_variant_label(record)
    name = record['name'].to_s.strip
    product = record['product_name'].to_s.strip
    return if name.blank? || name.casecmp?(product)
    return name if product.blank? || !name.downcase.start_with?(product.downcase)

    name[product.length..].to_s.sub(/\A[[:space:]\-–—·:,|\/]+/, '').strip.presence
  end

  # Word pill for the cashier. Out and Unknown are still addable (as before); checkout
  # re-reads stock and refuses an unknown or insufficient tracked quantity.
  def pos_stock_state(record)
    return { word: 'Not tracked', tone: 'pill-taupe', detail: 'Stock: Not tracked' } unless record['manage_stock']

    raw = record['quantity'].to_s
    return { word: 'Unknown', tone: 'pill-clay', detail: 'Stock: Unknown' } unless raw.match?(/\A-?\d{1,12}(?:\.\d{1,6})?\z/)

    quantity = BigDecimal(raw)
    shown = quantity.frac.zero? ? quantity.to_i.to_s : quantity.to_s('F')
    detail = "Stock: #{shown}"
    if quantity <= 0
      { word: 'Out', tone: 'pill-rose', detail: detail }
    elsif quantity <= LOW_STOCK
      { word: 'Low', tone: 'pill-clay', detail: detail }
    else
      { word: 'In stock', tone: 'pill-fern', detail: detail }
    end
  end

  def pos_addable?(record)
    record['price_cents'].is_a?(Integer) && !record['variable_price']
  end

  # Everything the item sheet shows for one variant. Display only: the price string is
  # never sent back; adding posts the variant id and quantity for a server quote.
  def pos_item_payload(record, image_links: false)
    stock = pos_stock_state(record)
    {
      id: record['id'], title: pos_product_title(record), variant: pos_variant_label(record), name: record['name'],
      sku: record['sku'], barcode: record['barcode'], category: record['category'].presence || 'Uncategorized',
      price: record['variable_price'] ? 'Variable price' : ctrax_money(record['price_cents']),
      addable: pos_addable?(record), stock: stock[:word], stock_tone: stock[:tone], stock_detail: stock[:detail],
      image: @images.url(record, size: 800),
      image_link_url: (ctrax_pos_image_path(@snapshot.location_id, record['id']) if image_links),
      image_product_id: (@images.product_for(record)&.id if image_links)
    }
  end

  # The tile payload plus the product's other sizes (cheapest first) as selectable chips.
  def pos_tile_payload(record, image_links: false)
    payload = pos_item_payload(record, image_links: image_links)
    siblings = Array(@variant_siblings&.dig(record['id']))
    if siblings.size > 1
      payload[:variants] = siblings.sort_by { |row| [row['price_cents'].is_a?(Integer) ? row['price_cents'] : Float::INFINITY, row['name'].to_s] }
        .map { |row| pos_item_payload(row, image_links: image_links) }
    end
    payload
  end

  def pos_setup_allowed?
    retail_business_access?('settings.write') && Current.user.can?('sales.write') && Current.user.can?('inventory.write')
  end

  # nil when the tender can be used for this cart, otherwise the reason in one sentence.
  # Mirrors the checks Pos::Checkout.prepare! makes; the server still decides.
  def pos_tender_blocker(tender, setting: @pos_setting, display: @display)
    return if display&.demo?

    if tender == 'card'
      return 'Card payments for this gateway are turned off until production use is confirmed' if setting&.gateway_provider == 'nmi' && !setting.nmi_sandbox?
      return 'Card payments are not set up for this store' unless setting&.card_enabled && setting.verified_at.present?
    else
      return 'Cash checkout is not turned on for this store' unless setting&.cash_enabled
    end
    nil
  end
end
