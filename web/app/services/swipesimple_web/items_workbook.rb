# frozen_string_literal: true

require 'bigdecimal'
require 'digest'
require 'stringio'
require 'zip'

module SwipesimpleWeb
  # Reads SwipeSimple's items.xlsx (sheets "Items" and "Taxes", found by name
  # through xl/workbook.xml and its relationships) into the record shape that
  # SwipesimpleItemImporter produces, so SwipesimpleItemMatch works unchanged.
  # Removed items are skipped. Stock is known only when SwipeSimple tracks
  # inventory for the item; otherwise it stays nil, never zero. A missing sheet,
  # unexpected headers or an unreadable cell fails the whole workbook.
  class ItemsWorkbook
    class Error < StandardError; end

    ITEM_HEADERS = %w[id name sku price tax status track_inventory on_hand_count category].freeze
    TAX_HEADERS = %w[id name value].freeze
    MAX_ENTRY_BYTES = 5 * 1024 * 1024
    MAX_ENTRIES = 200
    MAIN = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    RELS = 'http://schemas.openxmlformats.org/package/2006/relationships'
    DOC_RELS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    NS = { 'm' => MAIN }.freeze
    YES = %w[true yes y 1].freeze
    NO = %w[false no n 0].freeze
    NO_TAX = /\A(?:no tax|non[- ]?taxable|tax[- ]?exempt|exempt|none)\z/i

    def self.parse(bytes)
      new(bytes).records
    end

    def initialize(bytes)
      @bytes = bytes.to_s.b
    end

    def records
      raise Error, 'The items workbook is empty.' if @bytes.empty?

      @zip = Zip::File.open_buffer(StringIO.new(@bytes))
      raise Error, 'The items workbook has too many parts.' if @zip.size > MAX_ENTRIES

      @shared = shared_strings
      sheets = sheet_paths
      items = sheet_rows(sheets.fetch('Items') { raise Error, 'The items workbook has no Items sheet.' })
      taxes = sheet_rows(sheets.fetch('Taxes') { raise Error, 'The items workbook has no Taxes sheet.' })
      raise Error, 'The Items sheet headers changed.' unless header(items.shift) == ITEM_HEADERS
      raise Error, 'The Taxes sheet headers changed.' unless header(taxes.shift) == TAX_HEADERS
      raise Error, 'The Items sheet has too many rows.' if items.size > SwipesimpleItemImporter::MAX_ROWS

      rates = tax_rates(taxes)
      records = items.filter_map { |line, cells| record(line, cells, rates) }
      ids = records.map { |r| r['id'] }
      raise Error, 'An item ID appears more than once.' unless ids.uniq.size == ids.size

      records
    rescue Zip::Error, Nokogiri::XML::SyntaxError, ArgumentError, TypeError
      raise Error, 'The items workbook is not a readable .xlsx file.'
    end

    private

    def part(name, required: true)
      entry = @zip.find_entry(name)
      raise Error, "The items workbook is missing #{name}." if !entry && required
      return nil unless entry
      raise Error, 'An items workbook part is too large.' if entry.size > MAX_ENTRY_BYTES

      data = entry.get_input_stream.read(MAX_ENTRY_BYTES + 1).to_s
      raise Error, 'An items workbook part is too large.' if data.bytesize > MAX_ENTRY_BYTES

      Nokogiri::XML(data) { |config| config.strict.nonet }
    end

    def shared_strings
      document = part('xl/sharedStrings.xml', required: false)
      return [] unless document

      document.xpath('/m:sst/m:si', NS).map { |si| text_of(si) }
    end

    def text_of(node)
      node.xpath('.//m:t[not(ancestor::m:rPh)]', NS).map(&:text).join
    end

    # Sheet name → zip path, resolved through the workbook relationships.
    def sheet_paths
      targets = part('xl/_rels/workbook.xml.rels').xpath('/r:Relationships/r:Relationship', 'r' => RELS)
        .to_h { |rel| [rel['Id'], rel['Target'].to_s] }
      part('xl/workbook.xml').xpath('/m:workbook/m:sheets/m:sheet', NS).to_h do |sheet|
        target = targets[sheet.attribute_with_ns('id', DOC_RELS)&.value].to_s
        path = target.start_with?('/') ? target.delete_prefix('/') : "xl/#{target}"
        raise Error, 'The items workbook points outside its worksheets.' unless path.match?(%r{\Axl/worksheets/[A-Za-z0-9_]+\.xml\z})

        [sheet['name'].to_s, path]
      end
    end

    # [[row number, [cell strings by column]]] with blank rows dropped.
    def sheet_rows(path)
      part(path).xpath('/m:worksheet/m:sheetData/m:row', NS).filter_map do |row|
        cells = []
        row.xpath('m:c', NS).each_with_index do |cell, position|
          column = cell['r'] ? column_index(cell['r']) : position
          cells[column] = cell_value(cell)
        end
        cells = cells.map { |value| value.to_s.strip }
        [row['r'].to_i, cells] unless cells.all?(&:empty?)
      end
    end

    def column_index(reference)
      letters = reference[/\A([A-Z]{1,3})\d+\z/, 1] or raise Error, 'The items workbook has an unreadable cell reference.'
      letters.each_char.reduce(0) { |sum, char| (sum * 26) + (char.ord - 64) } - 1
    end

    def cell_value(cell)
      value = cell.at_xpath('m:v', NS)&.text
      case cell['t']
      when 's' then value.nil? ? '' : @shared.fetch(Integer(value, 10)) { raise Error, 'The items workbook references a missing shared string.' }
      when 'inlineStr' then (is = cell.at_xpath('m:is', NS)) ? text_of(is) : ''
      when 'b' then { '1' => 'true', '0' => 'false' }.fetch(value.to_s) { raise Error, 'The items workbook has an unreadable true/false cell.' }
      when 'e' then raise Error, 'The items workbook contains a cell error.'
      else value.to_s
      end
    end

    def header(row)
      cells = row&.last || []
      cells = cells[0...-1] while cells.any? && cells.last.empty?
      cells
    end

    def tax_rates(rows)
      rows.each_with_object({}) do |(line, cells), rates|
        name = cells[1].to_s
        raise Error, "Taxes row #{line} has no name." if name.empty?
        raise Error, "The tax #{name.first(40).inspect} appears more than once." if rates.key?(name)

        rate = number(cells[2], line, 'tax value')
        raise Error, "Taxes row #{line} has no usable rate." unless rate && rate >= 0 && rate <= 100

        rates[name] = rate
      end
    end

    def record(line, cells, rates)
      native = cells[0].to_s
      raise Error, "Items row #{line} has an unreadable ID." unless native.match?(/\A[1-9]\d{0,19}(?:\.0+)?\z/)

      native = native.sub(/\.0+\z/, '')
      name = cells[1].to_s
      raise Error, "Items row #{line} has no name." if name.empty?

      status = cells[5].to_s.downcase
      raise Error, "Items row #{line} has an unknown status." unless %w[active removed].include?(status)
      return nil if status == 'removed'

      tracked = boolean(cells[6], line)
      quantity = tracked ? number(cells[7], line, 'on_hand_count') : nil
      raise Error, "Items row #{line} has a fractional on-hand count." if quantity && quantity.frac.nonzero?

      price = number(cells[3], line, 'price')
      tax_label = cells[4].presence
      { 'id' => native, 'native_id' => native, 'name' => name, 'product_name' => name, 'variant' => nil, 'sku' => cells[2].presence,
        'barcode' => nil, 'price' => price&.to_s('F'), 'price_cents' => price && (price * 100).round.to_i,
        'quantity' => quantity&.to_i&.to_s, 'manage_stock' => tracked == true, 'category' => cells[8].presence,
        'tax_label' => tax_label, 'tax_rate' => tax_rate(tax_label, rates)&.to_s('F'), 'status' => status, 'line' => line }
    end

    # A label listed on the Taxes sheet uses its value; a "No Tax"-style label
    # is 0%; any other label keeps its name with an unknown rate.
    def tax_rate(label, rates)
      return nil unless label
      return rates[label] if rates.key?(label)

      label.match?(NO_TAX) ? BigDecimal('0') : nil
    end

    def boolean(value, line)
      text = value.to_s.downcase
      return nil if text.empty?
      return true if YES.include?(text)
      return false if NO.include?(text)

      raise Error, "Items row #{line} has an unreadable track_inventory value."
    end

    def number(value, line, label)
      text = value.to_s.delete('$,')
      return nil if text.empty?
      raise Error, "Row #{line}: #{label} is not a number." unless text.match?(/\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d{1,3})?\z/)

      BigDecimal(text)
    end
  end
end
