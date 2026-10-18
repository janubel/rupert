# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

# Built-in AFM fonts cover WinAnsi (the em dash / middle dot / accented Latin
# glyphs this report uses), so the per-document M17N warning is noise here.
Prawn::Fonts::AFM.hide_m17n_warning = true

# Builds the printable "Current Inventory Snapshot" for the Inventory page's
# Download PDF button. Data comes from the sync mirrors (refreshed every
# 15 minutes), so the PDF carries four timestamps: when the file was
# generated, the last successful overall sync, and the latest Shopify and
# Square mirror writes. Below the timestamps it shows summary totals, then a
# full per-variant table with Shopify qty, Square qty, and units sold in the
# last 7 days.
#
# Layout choices:
#   - items with zero stock on BOTH platforms are sorted to the bottom
#   - a compact 7pt row grid fits far more content per page
#
# Performance note: the catalog table is drawn with Prawn's low-level
# draw_text (no prawn-table Cell objects). Prawing 1900+ Cell objects to
# render a few hundred variant rows costs ~3s of pure Ruby; low-level text
# placement renders the same table in well under 200ms.
class InventoryPdf
  # Tailwind-ish neutrals that survive Prawn's base Helvetica palette.
  INK = '1C1917'
  MOCHA = '6B7280'
  TAUPE = 'A8A29E'
  FOG = 'D6D3D1'
  HAZE = 'EDEFF0'
  CREAM = 'FAFAF9'
  OLIVE = '5B7C41'
  ZERO_TINT = 'F5F0EC' # pale stone — zero-stock-on-both rows
  DUP_SKU_TINT = 'FDE8EA'  # pale rose — SKU reused by another product
  UNT_TINT = 'EFEFEC'      # pale gray — untracked (surplus/duplicate) variant, dimmed
  ROSE = 'B91C1C'

  Row = Struct.new(
    :product, :variant, :sku, :price, :shopify_qty, :square_qty,
    :sold_7d, :sold_shared, :shared_product_sku, :shared_qty, :square_variation_id,
    :tracked,
    keyword_init: true
  )

  # "—" for an unlinked variant's Square count, so the column reads like the
  # Inventory page table instead of showing a misleading zero.
  UNLINKED = '—'

  # Letter width 612 - 2×40 margin = 532pt of usable content width. These are
  # coordinates RELATIVE to the margin box (Prawn's draw_text/fill_rectangle
  # are relative, unlike screen coordinates) — (0,0) is the top-left of the
  # content area.
  HEADERS = ['Product', 'Variant', 'SKU', 'Price', 'Shopify', 'Square', '7d sold'].freeze
  COL_WIDTHS = [128, 104, 56, 46, 42, 54, 102].freeze
  LEFT_X = [0, 128, 232, 288, 334, 376, 430].freeze
  RIGHT_ALIGNED = [3, 4, 5, 6].freeze
  TABLE_WIDTH = 532
  ROW_HEIGHT = 12
  HEADER_HEIGHT = 14
  FONT_SIZE = 7
  FOOTER_TOP = 52
  SALES_DAYS = 7

  def self.build
    new.build
  end

  def build
    document.render
  end

  # The full per-variant snapshot the PDF renders (exposed for tests).
  def rows
    @rows ||= load_rows
  end

  # The Prawn document itself, exposed so tests can check page_count etc.
  def document
    @document ||= build_document
  end

  private

  def build_document
    summary = summarize(rows)
    timestamps = snapshot_timestamps
    attention = attention_items(rows)
    movers = top_movers(rows)
    sales_week = sales_week_data

    Prawn::Document.new(page_size: 'LETTER', margin: 40) do |pdf|
      write_title(pdf)
      write_stats(pdf, timestamps, summary)
      write_attention(pdf, attention)
      write_movers(pdf, movers)
      write_color_key(pdf)
      write_table(pdf, rows)
      pdf.start_new_page
      write_sales_week(pdf, sales_week)
      write_footer(pdf)
    end
  end

  def snapshot_timestamps
    {
      generated: Time.current,
      overall: last_successful_sync_time,
      shopify: ShopifyVariant.maximum(:syncedAt),
      square: SquareVariation.maximum(:syncedAt)
    }
  end

  def last_successful_sync_time
    run = SyncRun.where(status: 'success').order(finishedAt: :desc).first
    return nil unless run

    run.finishedAt || run.startedAt
  end

  # Mirrors the Inventory page's row shape (product-first ordering) but covers
  # the whole catalog rather than the page's 40-row preview. Zero-stock-on-both
  # rows are moved to the bottom so buyers see sellable stock first.
  def load_rows
    shopify_map = InventoryLevel.shopify_totals
    square_map = InventoryLevel.square_totals
    link_map = SkuLink.linked.index_by(&:shopifyVariantId)
    # Square variations linked to more than one Shopify variant (shared SKUs
    # like 689745640858 = multiple 12-count flavors). Their quantity can't be
    # attributed to a single row, so the Square column flags it with † instead
    # of repeating the aggregate total on every variant that links to it.
    shared_square_variations = SkuLink.linked.group(:squareVariationId).count.select { |_, n| n > 1 }.keys.to_set
    # SKUs attached to more than one Shopify variant (e.g. 689745640858 = both
    # Blue Raspberry and Blood Orange 12-count) can't be attributed to a single
    # variant from order lines — flag those rows so the sold count isn't read
    # as one variant's number. Products with several variants have the same
    # problem when a sale only matches by product name (Square order lines
    # often carry junk SKUs like "Regular").
    shared_skus = ShopifyVariant.where.not(sku: nil).group(:sku).count.select { |_, n| n > 1 }.keys
    multi_variant_products = ShopifyVariant.group(:productId).count.select { |_, n| n > 1 }.keys
    # SKUs reused by variants of different products (the web page's duplicate
    # SKU flag) — highlighted in rose so duplicate identifiers jump out.
    duplicate_product_skus = SkuRemediationPlanner.shared_skus

    rows = ShopifyProduct.active.order(:title).includes(:variants).flat_map do |product|
      ptitle = product.title.to_s.downcase
      product_has_variants = multi_variant_products.include?(product.id)
      product.variants.sort_by(&:title).filter_map do |variant|
        sku = variant.sku.to_s.downcase
        sku_shared = sku.present? && shared_skus.include?(variant.sku)
        sold, via_sku, via_name = count_sold(sku, ptitle)
        link = link_map[variant.id]
        square_qty = link ? square_map.fetch(link.squareVariationId, 0) : nil
        shopify_qty = shopify_map.fetch(variant.id, 0)
        # Skip inert, untracked helpers (e.g. ROUTEINS shipping insurance):
        # unlinked and with no stock on either platform, they're not inventory.
        next if !variant.tracked && link.nil? && shopify_qty.to_i <= 0

        Row.new(
          product: product.title,
          variant: variant.title,
          sku: variant.sku.presence || '—',
          price: variant.price,
          shopify_qty: shopify_qty,
          square_qty: square_qty,
          sold_7d: variant.sku.present? || ptitle.present? ? sold : nil,
          sold_shared: (sku_shared && via_sku) || (product_has_variants && via_name),
          shared_product_sku: variant.sku.present? && duplicate_product_skus.include?(variant.sku),
          shared_qty: link.present? && shared_square_variations.include?(link.squareVariationId),
          square_variation_id: link&.squareVariationId,
          tracked: variant.tracked
        )
      end
    end
    # Sort: tracked (canonical sellable) rows first — stocked first, then
    # zero-on-both — and UNTRACKED (surplus/duplicate) rows last, dimmed.
    tracked_rows, untracked_rows = rows.partition(&:tracked)
    zeroed, stocked = tracked_rows.partition { |row| zero_on_both?(row) }
    stocked + zeroed + untracked_rows
  end

  # Paid/fulfilled order lines in the window, as [sku, name, quantity] tuples
  # with the text already downcased so per-variant matching is cheap.
  def sales_lines
    @sales_lines ||= Core::OrderLine.joins(:order)
                                    .where(orders: { status: %w[paid fulfilled],
                                                     occurred_at: SALES_DAYS.days.ago.beginning_of_day..Time.current })
                                    .pluck(:sku, :name, :quantity)
                                    .map do |sku, name, qty|
      [
        sku.to_s.downcase, name.to_s.downcase, qty.to_i
      ]
    end
  end

  # Precomputed indexes over sales_lines so per-variant sold lookup is O(1)
  # instead of rescanning every line for every variant (O(variants × lines)).
  def sales_index
    @sales_index ||= begin
      by_sku = Hash.new(0)
      by_name = Hash.new(0)
      sku_name_overlap = Hash.new(0)
      sales_lines.each do |sku, name, qty|
        by_sku[sku] += qty if sku.present?
        by_name[name] += qty if name.present?
        sku_name_overlap[[sku, name]] += qty if sku.present? && name.present?
      end
      { by_sku: by_sku, by_name: by_name, overlap: sku_name_overlap }
    end
  end

  # Units sold for one variant, matching each order line by SKU OR by product
  # title (Square lines sometimes carry a bogus SKU like "Regular"). Returns
  # [units, matched_by_sku, matched_by_name]. A line matching both is counted
  # once (overlap is subtracted), preserving the old SKU-first semantics.
  def count_sold(sku, ptitle)
    idx = sales_index
    sku_units = sku.present? ? idx[:by_sku].fetch(sku, 0) : 0
    overlap = sku.present? && ptitle.present? ? idx[:overlap].fetch([sku, ptitle], 0) : 0
    name_units = ptitle.present? ? idx[:by_name].fetch(ptitle, 0) : 0
    [sku_units + name_units - overlap, sku.present? && idx[:by_sku].key?(sku), (name_units - overlap).positive?]
  end

  def zero_on_both?(row)
    # A row is non-sellable when Shopify has none, and Square is either also
    # non-positive or tied to no link (unknown → treated as no on-hand stock).
    # This makes unlinked 0-Shopify (dead) variants sort to the bottom and get
    # the stone tint just like verified-zero rows, instead of floating among
    # sellable stock.
    row.shopify_qty.to_i <= 0 && (row.square_qty.nil? || row.square_qty <= 0)
  end

  def summarize(rows)
    # Square units must not double-count a shared pool once per linked variant.
    # Sum each unique linked Square variation once (dedupe by square_variation_id).
    square_units = rows.each_with_object(Hash.new(0)) do |row, acc|
      next if row.square_qty.nil?

      acc[row.square_variation_id || row.variant] = row.square_qty.to_i
    end.values.sum

    {
      products: rows.map(&:product).uniq.size,
      variants: rows.length,
      shopify_units: rows.sum { |row| row.shopify_qty.to_i },
      square_units: square_units,
      sold_7d: sales_lines.sum { |_, _, qty| qty.to_i },
      valuation: rows.sum { |row| (row.price || 0).to_f * row.shopify_qty.to_i }
    }
  end

  # Compact header: small title, then one wide stat strip that pairs the four
  # timestamps with the six totals so the catalog table keeps most of the page.
  def write_title(pdf)
    pdf.text 'Current Inventory Snapshot', size: 14, style: :bold, color: INK
    pdf.move_down 2
    pdf.text tenant_line, size: 8, color: MOCHA
    pdf.move_down 8
  end

  def write_stats(pdf, timestamps, summary)
    data = [
      ['Generated at', fmt(timestamps[:generated]), 'Products', summary[:products].to_s],
      ['Overall sync', fmt(timestamps[:overall]), 'Tracked variants', summary[:variants].to_s],
      ['Shopify sync', fmt(timestamps[:shopify]), 'Mirrored (Shopify)', summary[:shopify_units].to_s],
      ['Square sync', fmt(timestamps[:square]), 'Mirrored (Square, linked)', summary[:square_units].to_s],
      ['', '', 'Sold last 7d (units)', summary[:sold_7d].to_s],
      ['', '', 'Retail value', format_currency(summary[:valuation])]
    ]
    pdf.table(data, width: TABLE_WIDTH, column_widths: [116, 184, 102, 130]) do |table|
      table.cells.style(
        padding: [2, 5],
        borders: [:bottom],
        border_color: FOG,
        size: 7,
        text_color: MOCHA
      )
      table.column(0).style(font_style: :bold, text_color: INK)
      table.column(1).style(text_color: INK)
      table.column(2).style(font_style: :bold, text_color: INK)
      table.column(3).style(font_style: :bold, text_color: INK, align: :right)
    end
    pdf.move_down 8
  end

  # -- Attention (what needs your time) --------------------------------------
  #
  # The report leads with exceptions instead of a flat dump: stockouts, drift,
  # negatives, and fast movers. `tracked` rows only (canonical sellable items).

  def attention_items(rows)
    tracked = rows.select(&:tracked)
    out_of_stock = tracked.select { |r| r.shopify_qty.to_i <= 0 && (r.square_qty.nil? || r.square_qty <= 0) }
    negative = tracked.select { |r| r.shopify_qty.to_i < 0 || (r.square_qty && r.square_qty < 0) }
    {
      out_of_stock: out_of_stock.sort_by { |r| r.shopify_qty.to_i },
      negative: negative.sort_by { |r| [r.shopify_qty.to_i, r.square_qty.to_i] }
    }
  end

  # Top movers by units sold, ONE entry per product (a product's multiple
  # strain variants share the same product-title match, so we collapse them to
  # the best variant rather than double-listing the same product 5x).
  def top_movers(rows)
    tracked = rows.select(&:tracked).select { |r| r.sold_7d.to_i.positive? }
    tracked.group_by(&:product).values
           .map { |vs| vs.max_by { |r| r.sold_7d.to_i } }
           .sort_by { |r| -r.sold_7d.to_i }
           .first(10)
  end

  def write_attention(pdf, attention)
    has_any = attention.values.any?(&:present?)
    pdf.move_down 6
    pdf.fill_color INK
    pdf.text 'Needs attention', size: 11, style: :bold
    unless has_any
      pdf.text 'No stockouts or negatives right now — the catalog is in good shape.', size: 8, color: OLIVE
      pdf.move_down 6
      return
    end

    groups = {
      'Out of stock' => attention[:out_of_stock],
      'Negative stock' => attention[:negative]
    }
    groups.each do |label, list|
      next if list.empty?

      pdf.fill_color HAZE
      pdf.fill_rectangle [0, pdf.cursor + 3], TABLE_WIDTH, 14
      pdf.fill_color INK
      pdf.text "#{label} — #{list.length}", size: 8, style: :bold
      pdf.move_down 2
      list.first(8).each do |r|
        pdf.text "  • #{r.product[0, 34]} — #{r.variant[0, 20]} (#{r.sku})  Sh #{r.shopify_qty.to_i}  Sq #{r.square_qty&.to_s || '—'}",
          size: 7, color: MOCHA
      end
      pdf.text("  … +#{list.length - 8} more", size: 6.5, color: TAUPE) if list.length > 8
      pdf.move_down 5
    end
    pdf.move_down 3
  end

  def write_movers(pdf, movers)
    return if movers.empty?

    pdf.text 'Top movers — units sold (7d)', size: 11, style: :bold
    rows = movers.map { |r| [r.product[0, 46], r.variant[0, 30], r.sold_7d.to_s, r.shopify_qty.to_s] }
    pdf.table(rows, width: TABLE_WIDTH, header: true, column_widths: [250, 130, 76, 76]) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = HAZE
      t.cells.size = 7
      t.cells.padding = [2, 4]
      t.cells.border_color = FOG
      t.cells.text_color = MOCHA
      t.column(2).align = :right
      t.column(3).align = :right
    end
    pdf.move_down 8
  end

  # --- Catalog table ---------------------------------------------------------
  #
  # Hand-rolled rows with draw_text (no prawn-table cells): ~16x faster than
  # prawn-table for catalogs of a few hundred rows.

  def write_table(pdf, rows)
    if rows.empty?
      pdf.text 'No inventory mirrored yet — run a sync from the Sync page.', size: 10, color: TAUPE
      return
    end

    pdf.font 'Helvetica', size: FONT_SIZE
    y = pdf.cursor
    draw_table_header(pdf, y)
    y -= HEADER_HEIGHT + 3

    rows.each_with_index do |row, index|
      if y - ROW_HEIGHT < FOOTER_TOP
        pdf.start_new_page
        y = pdf.cursor
        draw_table_header(pdf, y)
        y -= HEADER_HEIGHT + 3
      end

      draw_row_background(pdf, row, y, index)
      draw_row(pdf, row, y)
      pdf.stroke_color FOG
      # Separator between rows — at the row's bottom edge, never through the
      # glyphs (text baseline is y - ROW_HEIGHT/2 + 1, so the line at the bottom
      # edge stays clear of the text).
      pdf.stroke_horizontal_line 0, TABLE_WIDTH, at: y - ROW_HEIGHT + 1
      y -= ROW_HEIGHT
    end
  end

  def draw_table_header(pdf, y)
    pdf.fill_color HAZE
    pdf.fill_rectangle [0, y], TABLE_WIDTH, HEADER_HEIGHT
    pdf.fill_color MOCHA
    pdf.font 'Helvetica', style: :bold
    HEADERS.each_with_index do |header, i|
      pdf.draw_text header, at: [LEFT_X[i] + 4, y - HEADER_HEIGHT / 2 + 1], size: FONT_SIZE
    end
    pdf.font 'Helvetica', style: :normal
    pdf.fill_color INK
  end

  # Highlights differences: duplicate-SKU rows get a rose tint (the web page's
  # "duplicate SKU" flag), zero-stock rows stone, and the rest keep the subtle
  # cream zebra stripe.
  def draw_row_background(pdf, row, y, index)
    if !row.tracked
      pdf.fill_color UNT_TINT
    elsif row.shared_product_sku
      pdf.fill_color DUP_SKU_TINT
    elsif zero_on_both?(row)
      pdf.fill_color ZERO_TINT
    elsif index.even?
      pdf.fill_color CREAM
    else
      return
    end
    pdf.fill_rectangle [0, y], TABLE_WIDTH, ROW_HEIGHT
    pdf.fill_color INK
  end

  def draw_row(pdf, row, y)
    cells = [
      row.product,
      row.variant,
      row.sku,
      row.price.nil? ? '—' : format_currency(row.price),
      row.shopify_qty.to_s,
      square_cell(row),
      sold_cell(row)
    ]
    baseline = y - ROW_HEIGHT / 2 + 1
    cells.each_with_index do |cell, i|
      pdf.fill_color cell_color(i, row)
      bold = bold_cell?(i, row)
      pdf.font('Helvetica', style: :bold) if bold
      x = if RIGHT_ALIGNED.include?(i)
        LEFT_X[i] + COL_WIDTHS[i] - 3 - pdf.width_of(cell)
      else
        LEFT_X[i] + 4
          end
      pdf.draw_text fit_text(pdf, cell, COL_WIDTHS[i] - 7), at: [x, baseline], size: FONT_SIZE
      pdf.font('Helvetica', style: :normal) if bold
    end
    pdf.fill_color INK
  end

  # "2†" marks a shared SKU: the count covers every variant carrying that SKU,
  # so it can't be pinned to this one variant (see the footer legend).
  def sold_cell(row)
    return '—' if row.sold_7d.nil?

    row.sold_shared && row.sold_7d.positive? ? "#{row.sold_7d}†" : row.sold_7d.to_s
  end

  # The Square quantity, flagged with † when the linked Square variation is
  # shared by more than one Shopify variant — the aggregate can't be attributed
  # to this row alone, so it's marked instead of silently repeated.
  def square_cell(row)
    return UNLINKED if row.square_qty.nil?

    row.shared_qty ? "#{row.square_qty}†" : row.square_qty.to_s
  end

  def cell_color(index, row)
    return TAUPE unless row.tracked # untracked (surplus) rows render dimmed

    if index == 2 && row.shared_product_sku
      ROSE
    elsif index == 6 && !row.sold_7d.nil? && row.sold_7d.positive?
      OLIVE
    elsif index.zero?
      INK
    else
      MOCHA
    end
  end

  def bold_cell?(index, row)
    return false unless row.tracked

    (index == 2 && row.shared_product_sku) ||
      (index == 6 && !row.sold_7d.nil? && row.sold_7d.positive?)
  end

  # Truncate to the column width with an ellipsis so long product/variant names
  # never spill into the next column.
  def fit_text(pdf, text, max_width)
    text = text.to_s
    return text if pdf.width_of(text) <= max_width

    ellipsis = '…'
    clipped = text.dup
    clipped = clipped[0...-1] while clipped.length > 1 && pdf.width_of(clipped + ellipsis) > max_width
    clipped + ellipsis
  end

  # --- Last 7 days sales ------------------------------------------------------
  #
  # Newest day first; each day shows the total units sold plus every paid or
  # fulfilled transaction that day so the report doubles as a reconciliation
  # aid against Shopify and Square.

  def sales_week_data
    orders = Core::Order.includes(:order_lines)
                        .where(occurred_at: SALES_DAYS.days.ago.beginning_of_day..Time.current)
                        .where(status: %w[paid fulfilled])
                        .order(occurred_at: :desc)
    orders.group_by { |order| order.occurred_at.to_date }
          .sort { |(date_a, _), (date_b, _)| date_b <=> date_a }
  end

  # Last-7-days transaction layout (manual rows, same as the catalog table).
  SALES_HEADERS = %w[Time Order Source Items Units Amount].freeze
  SALES_COL_WIDTHS = [44, 118, 60, 174, 40, 96].freeze
  SALES_LEFT_X = [0, 44, 162, 222, 396, 436].freeze
  SALES_RIGHT = [4, 5].freeze
  DAY_HEADER_HEIGHT = 14
  SALES_ROW_HEIGHT = 11

  def write_sales_week(pdf, sales_week)
    pdf.text 'Sales · Last 7 Days', size: 12, style: :bold, color: INK
    pdf.move_down 6
    y = pdf.cursor

    if sales_week.empty?
      pdf.text "No paid or fulfilled sales in the last #{SALES_DAYS} days.", size: 8, color: TAUPE
      return
    end

    pdf.font 'Helvetica', size: FONT_SIZE
    sales_week.each do |date, orders|
      units = orders.sum { |order| order.order_lines.sum(&:quantity) }
      revenue = orders.sum(&:gross_cents) / 100.0
      needed = DAY_HEADER_HEIGHT + 3 + SALES_ROW_HEIGHT + orders.length * SALES_ROW_HEIGHT

      if y - needed < FOOTER_TOP
        pdf.start_new_page
        y = pdf.cursor
      end

      # Day header (label + right-aligned daily total).
      pdf.fill_color HAZE
      pdf.fill_rectangle [0, y], TABLE_WIDTH, DAY_HEADER_HEIGHT
      pdf.fill_color INK
      pdf.font 'Helvetica', style: :bold
      pdf.draw_text date.strftime('%A, %B %-e, %Y'), at: [4, y - DAY_HEADER_HEIGHT / 2 + 1], size: 8
      total = "#{units} units · #{format_currency(revenue)}"
      pdf.draw_text total, at: [TABLE_WIDTH - 4 - pdf.width_of(total), y - DAY_HEADER_HEIGHT / 2 + 1], size: 8
      pdf.font 'Helvetica', style: :normal
      y -= DAY_HEADER_HEIGHT + 3

      # Column header.
      pdf.fill_color MOCHA
      pdf.font 'Helvetica', style: :bold
      SALES_HEADERS.each_with_index do |header, i|
        pdf.draw_text header, at: [SALES_LEFT_X[i] + 4, y - SALES_ROW_HEIGHT / 2 + 1], size: FONT_SIZE
      end
      pdf.font 'Helvetica', style: :normal
      pdf.fill_color INK
      y -= SALES_ROW_HEIGHT

      orders.each do |order|
        if y - SALES_ROW_HEIGHT < FOOTER_TOP
          pdf.start_new_page
          y = pdf.cursor
        end

        cells = [
          order.occurred_at.in_time_zone.strftime('%-l:%M %p'),
          order.display_number,
          order.source.to_s.capitalize,
          item_summary(order),
          order.order_lines.sum(&:quantity).to_s,
          format_currency(order.gross_cents.to_i / 100.0)
        ]
        baseline = y - SALES_ROW_HEIGHT / 2 + 1
        cells.each_with_index do |cell, i|
          pdf.fill_color i == 5 ? INK : MOCHA
          pdf.font('Helvetica', style: :bold) if i == 5
          x = if SALES_RIGHT.include?(i)
            SALES_LEFT_X[i] + SALES_COL_WIDTHS[i] - 3 - pdf.width_of(cell)
          else
            SALES_LEFT_X[i] + 4
              end
          pdf.draw_text fit_text(pdf, cell, SALES_COL_WIDTHS[i] - 7), at: [x, baseline], size: FONT_SIZE
          pdf.font('Helvetica', style: :normal) if i == 5
        end
        pdf.fill_color INK
        pdf.stroke_color FOG
        pdf.stroke_horizontal_line 0, TABLE_WIDTH, at: y - SALES_ROW_HEIGHT + 1
        y -= SALES_ROW_HEIGHT
      end
      y -= 6
    end
  end

  # Product name first (order lines carry the platform's item title, e.g.
  # "30mg THC Gummies - Blood Orange - Sativa") so each transaction matches a
  # product at a glance; the SKU rides along in parentheses when present.
  def item_summary(order)
    order.order_lines.map do |line|
      label = line.name.presence || line.sku.presence || 'item'
      label += " (#{line.sku})" if line.sku.present? && line.sku != line.name
      "#{line.quantity}× #{label}"
    end.join(', ')
  end

  # A printed key/legend at the top of the report explaining the catalog-table
  # highlighting (row tints), the duplicate-name/SKU marking, and the † and —
  # markers — so buyers/readers can decode the table before they read it.
  # Rendered as a Prawn table so the color swatches lay out reliably.
  def write_color_key(pdf)
    pdf.move_down 8
    pdf.fill_color HAZE
    pdf.fill_rectangle [0, pdf.cursor + 6], TABLE_WIDTH, 20
    pdf.fill_color INK
    pdf.text 'How to read this report', size: 9, style: :bold
    pdf.move_down 4

    swatches = [DUP_SKU_TINT, UNT_TINT, ZERO_TINT, CREAM, nil, nil, nil]
    labels = [
      'Rose row — DUPLICATE NAME/SKU: this SKU is reused by another product, which breaks Shopify–Square linking',
      'GRAY row, dimmed & at the bottom — UNTRACKED variant: a surplus duplicate of a SKU that already has one real (tracked) product; excluded from sync/reconcile',
      'Stone row — out of stock on both platforms (sorted to the bottom)',
      'Zebra stripe — alternating rows for readability',
      "† in the Square/7d columns — a shared SKU: the total spans multiple variations and can't be pinned to this row",
      "#{UNLINKED} under Square — no Square link for this variant",
      "7d sold in green — paid/fulfilled units in the last #{SALES_DAYS} days"
    ]
    data = swatches.each_index.map { |i| [swatches[i].nil? ? '' : ' ', labels[i]] }
    table = pdf.make_table(data, width: TABLE_WIDTH, cell_style: {
                             size: 6.8, color: MOCHA, border_width: 0, padding: [2, 4], valign: :center
                           }) do |t|
      t.column(0).width = 22
    end
    swatches.each_with_index { |color, i| table.row(i).column(0).background_color = color if color }
    table.draw
    pdf.move_down 6
    pdf.fill_color INK
  end

  def write_footer(pdf)
    pdf.move_down 10
    pdf.text(
      'Generated by Rupert. Quantities are mirrored from Shopify and Square and refresh every 15 minutes. ' \
      'The Square column is the sum across every active Square location (physical shop + mobile events). ' \
      'rose rows reuse a SKU on another product (breaks Shopify-Square linking); ' \
      'tinted rows show a Shopify vs Square difference; zero-stock rows sit at the bottom; ' \
      "7d sold counts paid/fulfilled orders from the last #{SALES_DAYS} days by SKU or product name; " \
      '† = shared SKU / product match — the sold figure and the Square quantity shared across ' \
      "multiple variants can't be pinned to this exact row, see the Sales section; " \
      "unlinked variants show #{UNLINKED} for Square.",
      size: 6.5, color: TAUPE
    )
    pdf.number_pages(
      'Page <page> of <total>',
      at: [pdf.bounds.left, 16],
      width: pdf.bounds.width,
      align: :right,
      size: 6.5,
      color: TAUPE
    )
  end

  def tenant_line
    name = Current.respond_to?(:tenant) && Current.tenant
    base = 'Rupert · Shopify + Square inventory mirror'
    name ? "#{base} — #{name.name}" : base
  end

  def format_currency(amount)
    format('$%.2f', amount.to_f)
  end

  # Localized * app timezone, e.g. "August 17, 2026 · 2:05 PM UTC".
  def fmt(time)
    return '—' if time.nil?

    time.in_time_zone.strftime('%B %-e, %Y · %-l:%M %p %Z')
  end
end
