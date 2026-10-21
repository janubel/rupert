# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

Prawn::Fonts::AFM.hide_m17n_warning = true

# Three printable sheets built from ProductNameCrosswalk:
#   crosswalk - the current website catalog A-Z with each system's name
#   verify    - matches the system is unsure about, with a tick box
#   unmatched - secondary items with no website match, with a write-in column
class ProductNamePdf
  SHEETS = {
    'crosswalk' => 'Product name crosswalk',
    'verify' => 'Names to verify',
    'unmatched' => 'Unmatched items worksheet'
  }.freeze
  FOG = 'D6D3D1'
  HAZE = 'EDEFF0'
  MOCHA = '6B7280'

  def self.build(sheet, crosswalk, at: Time.current)
    new(sheet, crosswalk, at).build
  end

  def initialize(sheet, crosswalk, at)
    raise ArgumentError, "Unknown sheet #{sheet}" unless SHEETS.key?(sheet)

    @sheet = sheet
    @crosswalk = crosswalk
    @at = at
  end

  def build
    pdf = Prawn::Document.new(page_size: 'LETTER', page_layout: :landscape, margin: [30, 28, 36, 28], info: { Title: SHEETS.fetch(@sheet) })
    pdf.font_size 7
    pdf.text SHEETS.fetch(@sheet), size: 14, style: :bold
    pdf.fill_color MOCHA
    pdf.text subtitle, size: 8
    pdf.fill_color '000000'
    pdf.move_down 6
    header, data, widths = table
    if data.empty?
      pdf.text 'Nothing to list.'
    else
      pdf.table([header] + data, header: true, width: widths.sum, column_widths: widths,
        cell_style: { size: 7, padding: [3, 4], border_width: 0.25, border_color: FOG }) do |t|
        t.row(0).font_style = :bold
        t.row(0).background_color = HAZE
      end
    end
    pdf.number_pages "#{SHEETS.fetch(@sheet)} - Rupert, #{@at.strftime('%Y-%m-%d %H:%M')} - page <page> of <total>",
      at: [0, -22], width: pdf.bounds.width, size: 7, align: :left
    pdf.render
  end

  private

  def subtitle
    case @sheet
    when 'crosswalk' then 'Website (Shopify) name is primary. Blank means no match in that system. Current catalog, A-Z.'
    when 'verify' then 'Matches the system is unsure about: fuzzy matches and SKUs shared by very different names. Tick when checked.'
    else 'Secondary-system items with no website match. Write the correct website name in the last column.'
    end
  end

  def table
    case @sheet
    when 'crosswalk'
      rows = @crosswalk.rows.sort_by { |r| r[:key] }
      [%w[Website\ name\ (primary) SKU Square SwipeSimple C-Trax],
       rows.map { |r| [r[:name], r[:sku], r.dig(:square, :name), r.dig(:swipesimple, :name), r.dig(:ctrax, :name)].map(&:to_s) },
       [270, 60, 170, 130, 110]]
    when 'verify'
      [['Done', 'Website name (primary)', 'SKU', 'Square', 'SwipeSimple', 'C-Trax', 'Why'],
       @crosswalk.verify_rows.map { |r| ['', r[:name], r[:sku], r.dig(:square, :name), r.dig(:swipesimple, :name), r.dig(:ctrax, :name), r[:issues].join('; ')].map(&:to_s) },
       [32, 170, 55, 115, 100, 100, 168]]
    else
      items = @crosswalk.unmatched.slice(:swipesimple, :ctrax).flat_map do |system, list|
        list.reject { |item| system == :ctrax && item[:note] == 'Not listed for sale' }.map { |item| [ProductNameCrosswalk::SYSTEMS.fetch(system), item] }
      end
      [['Done', 'System', 'Item name', 'SKU', 'Category', 'Suggested (review)', 'Website name (write in)'],
       items.sort_by { |system, item| [system, ProductNameCrosswalk.normalize(item[:name])] }.map do |system, item|
         ['', system, item[:name], item[:sku], item[:category], item[:suggestion], ''].map(&:to_s)
       end,
       [32, 62, 170, 55, 90, 165, 164]]
    end
  end
end
