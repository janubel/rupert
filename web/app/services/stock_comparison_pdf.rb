# frozen_string_literal: true

require 'bigdecimal'
require 'prawn'

Prawn::Fonts::AFM.hide_m17n_warning = true

# Printable Shopify / C-Trax stock comparison: the same rows, filter and search
# as the Stock comparison page, with both source read times so a printout is
# never mistaken for live stock. Read-only; nothing here writes anywhere.
#
# The row table is drawn with Prawn's low-level draw_text (like InventoryPdf)
# instead of prawn-table, so a few thousand rows render in about a second.
class StockComparisonPdf
  INK = '1C1917'
  MOCHA = '6B7280'
  TAUPE = 'A8A29E'
  FOG = 'D6D3D1'
  HAZE = 'EDEFF0'
  CLAY = 'B45309'
  ROSE = 'B91C1C'
  ISSUE_TINT = 'FDF0E6'

  FILTERS = {
    'all' => 'All items', 'attention' => 'Needs attention', 'unmatched' => 'No current pair',
    'candidates' => 'Product/package candidates', 'findings' => 'Saved investigation findings',
    'historical' => 'Historical Shopify candidates'
  }.freeze

  # Landscape Letter: 792 - 2 x 36 margin = 720pt of content width.
  HEADERS = ['Item', 'SKU', 'Identity', 'Shopify on hand', 'C-Trax stock', 'Difference', 'Issues'].freeze
  WIDTHS = [210, 78, 112, 54, 54, 54, 158].freeze
  LEFT_X = WIDTHS.each_with_index.map { |_, i| WIDTHS.first(i).sum }.freeze
  NUMERIC = [3, 4, 5].freeze
  TABLE_WIDTH = WIDTHS.sum
  FONT_SIZE = 7
  LINE_HEIGHT = 8.5
  MAX_LINES = 3
  PADDING = 3
  HEADER_HEIGHT = 20
  BOTTOM = 14

  def initialize(comparison, business_name: TenantSettings.business_name, at: Time.current)
    @comparison = comparison
    @business_name = business_name
    @at = at
  end

  def render = document.render

  def document
    @document ||= Prawn::Document.new(page_size: 'LETTER', page_layout: :landscape, margin: 36, compress: true,
      info: { Title: 'Shopify and C-Trax stock comparison', Creator: 'Rupert' }).tap { |pdf| draw(pdf) }
  end

  private

  def draw(pdf)
    pdf.font('Helvetica')
    pdf.fill_color(INK)
    write_heading(pdf)
    write_table(pdf, @comparison.rows)
    pdf.number_pages('Page <page> of <total>', at: [pdf.bounds.right - 120, -10], width: 120, align: :right, size: 8, color: MOCHA)
    pdf.number_pages("#{plain(@business_name)} · stock comparison generated #{time(@at)} · read-only",
      at: [0, -10], width: 500, size: 8, color: MOCHA)
  end

  def write_heading(pdf)
    shopify = @comparison.shopify
    ctrax = @comparison.ctrax
    pdf.text("#{plain(@business_name)} · Shopify & C-Trax stock comparison", size: 15, style: :bold)
    pdf.text("Shopify location: #{plain(shopify&.location&.name || 'Not selected')}   vs   C-Trax store: #{plain(ctrax&.location&.name || 'Not selected')}",
      size: 10)
    pdf.move_down(2)
    pdf.text("Generated #{time(@at)} · Shopify read #{read_time(shopify)} · C-Trax read #{read_time(ctrax)}", size: 8, color: MOCHA)
    stale = [['Shopify', shopify], ['C-Trax', ctrax]].filter_map do |label, snapshot|
      if snapshot.nil?
        "#{label} stock read is missing"
      elsif @comparison.stale?(snapshot)
        "#{label} stock read is STALE (older than one hour)"
      end
    end
    if stale.any?
      pdf.text("#{stale.join('; ')}. Quantity differences are withheld for stale or missing reads.", size: 9, style: :bold, color: CLAY)
    end
    shown = "Showing: #{FILTERS.fetch(@comparison.filter)}"
    shown += " · search \"#{plain(@comparison.query)}\"" if @comparison.query.present?
    pdf.text("#{shown} · #{@comparison.rows.size} rows", size: 9)
    s = @comparison.summary
    pdf.text("Summary: #{s[:rows]} comparison rows · #{s[:paired]} identity pairs/candidates · #{s[:unpaired]} without a current pair · " \
             "#{s[:unknown]} unknown stock · #{s[:negative]} negative stock · #{s[:name_candidates]} name/package candidates · " \
             "#{s[:historical]} historical candidates · #{s[:findings]} with investigation findings",
      size: 8, color: MOCHA)
    pdf.text('Difference = C-Trax stock - Shopify on hand; blank when withheld (unknown, stale, fractional, untracked or candidate-only rows). ' \
             'Unknown stock is never treated as 0. Shopify and C-Trax quantities are two observations of the same stock and are never added.',
      size: 7, color: MOCHA)
    pdf.move_down(8)
  end

  def write_table(pdf, rows)
    if rows.empty?
      pdf.text('No current records match these filters.', size: 10, color: MOCHA)
      return
    end

    pdf.font('Helvetica', size: FONT_SIZE)
    y = pdf.cursor
    y = draw_header(pdf, y)
    rows.each do |row|
      cells = cells_for(pdf, row)
      height = (cells.map(&:size).max * LINE_HEIGHT) + (PADDING * 2) - 1
      if y - height < BOTTOM
        pdf.start_new_page
        y = draw_header(pdf, pdf.bounds.top)
      end
      draw_row(pdf, row, cells, y, height)
      y -= height
    end
  end

  def draw_header(pdf, y)
    pdf.fill_color(HAZE)
    pdf.fill_rectangle([0, y], TABLE_WIDTH, HEADER_HEIGHT)
    pdf.fill_color(MOCHA)
    pdf.font('Helvetica', style: :bold) do
      HEADERS.each_with_index do |header, i|
        lines = NUMERIC.include?(i) ? header.split(' ', 2) : [header]
        lines.each_with_index do |line, n|
          x = NUMERIC.include?(i) ? LEFT_X[i] + WIDTHS[i] - PADDING - pdf.width_of(line, size: FONT_SIZE) : LEFT_X[i] + PADDING
          pdf.draw_text(line, at: [x, y - 8 - (n * LINE_HEIGHT)], size: FONT_SIZE)
        end
      end
    end
    pdf.fill_color(INK)
    y - HEADER_HEIGHT
  end

  def draw_row(pdf, row, cells, y, height)
    if row[:issues].any?
      pdf.fill_color(ISSUE_TINT)
      pdf.fill_rectangle([0, y], TABLE_WIDTH, height)
    end
    cells.each_with_index do |lines, i|
      pdf.fill_color(color_for(row, i))
      lines.each_with_index do |line, n|
        x = NUMERIC.include?(i) ? LEFT_X[i] + WIDTHS[i] - PADDING - pdf.width_of(line) : LEFT_X[i] + PADDING
        pdf.draw_text(line, at: [x, y - PADDING - 6 - (n * LINE_HEIGHT)])
      end
    end
    pdf.stroke_color(FOG)
    pdf.stroke_horizontal_line(0, TABLE_WIDTH, at: y - height)
    pdf.fill_color(INK)
  end

  def cells_for(pdf, row)
    issues = row[:issues].dup
    issues << 'Not listed for sale' if row[:ctrax_id] && !row[:listed]
    texts = [row[:label], row[:sku].presence || 'No SKU', row[:identity],
      quantity(row[:on_hand], row[:shopify_id]), quantity(row[:ctrax_quantity], row[:ctrax_id]),
      row[:difference].nil? ? '' : signed(row[:difference]), issues.join('; ')]
    texts.each_with_index.map { |text, i| wrap(pdf, plain(text), WIDTHS[i] - (PADDING * 2)) }
  end

  def color_for(row, index)
    case index
    when 0 then INK
    when 3, 4
      value = index == 3 ? row[:on_hand] : row[:ctrax_quantity]
      value.nil? ? TAUPE : (value.negative? ? ROSE : INK)
    when 5 then row[:difference]&.nonzero? ? ROSE : INK
    when 6 then CLAY
    else MOCHA
    end
  end

  # Unknown stays "Unknown" (never 0); a side with no matching item says so.
  def quantity(value, source_id)
    return source_id ? 'Unknown' : 'No match' if value.nil?

    number(value)
  end

  def signed(value) = value.positive? ? "+#{number(value)}" : number(value)

  def number(value) = value.is_a?(BigDecimal) ? value.to_s('F').delete_suffix('.0') : value.to_s

  # Greedy word wrap into at most MAX_LINES lines; the last line is clipped
  # with an ellipsis so long names never spill into the next column.
  def wrap(pdf, text, width)
    return [text] if text.empty? || pdf.width_of(text) <= width

    lines = []
    current = +''
    text.split(/\s+/).each do |word|
      candidate = current.empty? ? word : "#{current} #{word}"
      if pdf.width_of(candidate) <= width || current.empty?
        current = candidate
      else
        lines << current
        current = word
      end
    end
    lines << current
    lines = lines.first(MAX_LINES).tap { |kept| kept[-1] = "#{kept[-1]} #{lines[MAX_LINES..].join(' ')}" } if lines.size > MAX_LINES
    lines.map { |line| clip(pdf, line, width) }
  end

  def clip(pdf, text, width)
    return text if pdf.width_of(text) <= width

    text = text[0...-1] while text.length > 1 && pdf.width_of("#{text}...") > width
    "#{text}..."
  end

  def read_time(snapshot) = snapshot ? time(snapshot.captured_at) : 'missing'

  def time(value) = value.in_time_zone.strftime('%b %-d, %Y %-I:%M %p %Z')

  # Built-in PDF fonts only cover Windows-1252; replace anything else.
  def plain(text) = text.to_s.encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?').encode('UTF-8')
end
