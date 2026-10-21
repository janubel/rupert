# frozen_string_literal: true

require 'nokogiri'

module Uploads
  # Reads the first rows of the first worksheet of an .xlsx for preview and
  # sniffing. Cached values only: formulas are never evaluated, links never
  # followed, macros and external data never touched. Pull parsing under size caps.
  class XlsxReader
    Error = ZipInspector::Error
    PARSE = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::NOBLANKS
    ELEMENT = Nokogiri::XML::Reader::TYPE_ELEMENT
    END_ELEMENT = Nokogiri::XML::Reader::TYPE_END_ELEMENT
    TEXT_TYPES = [Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA].freeze
    MAX_SHARED_STRINGS = 200_000

    Sheet = Struct.new(:name, :path, keyword_init: true)

    def initialize(bytes)
      @zip = ZipInspector.new(bytes)
      raise Error, 'Not an Excel workbook (missing workbook parts).' unless @zip.entry('[Content_Types].xml') && @zip.entry('xl/workbook.xml')
    end

    def sheets
      @sheets ||= read_sheets
    end

    def macros?
      @zip.entries.any? { |entry| entry.name.casecmp?('xl/vbaProject.bin') }
    end

    def rows(limit: Limits::SAMPLE_ROWS, sheet: sheets.first)
      return [] unless sheet

      xml = @zip.read(sheet.path) or return []
      strings = shared_strings
      result = []
      row = cell = nil
      collecting = false
      reader(xml).each do |node|
        case node.node_type
        when ELEMENT
          case node.name
          when 'row' then row = {}
          when 'c'
            column = column_index(node.attribute('r'))
            column = row ? row.size : 0 if column.negative?
            cell = { col: column, type: node.attribute('t'), text: +'' }
            if node.empty_element?
              row[cell[:col]] = '' if row
              cell = nil
            end
          when 'v', 't' then collecting = !cell.nil?
          end
        when *TEXT_TYPES
          cell[:text] << node.value.to_s if cell && collecting
        when END_ELEMENT
          case node.name
          when 'v', 't' then collecting = false
          when 'c'
            row[cell[:col]] = resolve(cell, strings) if row && cell
            cell = nil
          when 'row'
            result << dense(row) if row
            row = nil
            break if result.size >= limit
          end
        end
      end
      result
    end

    private

    def reader(xml) = Nokogiri::XML::Reader(xml, nil, nil, PARSE)

    def read_sheets
      doc = Nokogiri::XML(@zip.read('xl/workbook.xml'), nil, nil, PARSE)
      targets = relationships
      doc.xpath('//*[local-name()="sheet"]').first(50).filter_map do |node|
        id = node.attribute_with_ns('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')&.value
        path = targets[id] or next
        Sheet.new(name: node['name'].to_s.first(80), path: path)
      end
    end

    def relationships
      xml = @zip.read('xl/_rels/workbook.xml.rels') or return {}
      Nokogiri::XML(xml, nil, nil, PARSE).xpath('//*[local-name()="Relationship"]').to_h do |node|
        target = node['Target'].to_s
        [node['Id'], target.start_with?('/') ? target.delete_prefix('/') : "xl/#{target}"]
      end
    end

    def shared_strings
      @shared_strings ||= begin
        xml = @zip.read('xl/sharedStrings.xml')
        xml ? parse_shared_strings(xml) : []
      end
    end

    def parse_shared_strings(xml)
      strings = []
      current = nil
      in_phonetic = false
      collecting = false
      reader(xml).each do |node|
        case node.node_type
        when ELEMENT
          case node.name
          when 'si' then current = +''
          when 'rPh' then in_phonetic = true
          when 't' then collecting = !in_phonetic
          end
        when *TEXT_TYPES
          current << node.value.to_s if current && collecting
        when END_ELEMENT
          case node.name
          when 't' then collecting = false
          when 'rPh' then in_phonetic = false
          when 'si'
            strings << current
            current = nil
            break if strings.size >= MAX_SHARED_STRINGS
          end
        end
      end
      strings
    end

    def resolve(cell, strings)
      case cell[:type]
      when 's' then strings[cell[:text].to_i].to_s
      when 'b' then cell[:text] == '1' ? 'TRUE' : 'FALSE'
      else cell[:text]
      end
    end

    def column_index(ref)
      letters = ref.to_s[/\A[A-Z]+/].to_s
      letters.each_char.reduce(0) { |sum, char| (sum * 26) + (char.ord - 64) } - 1
    end

    def dense(row)
      return [] if row.empty?

      Array.new([row.keys.max + 1, Limits::PREVIEW_COLS * 2].min) { |index| row[index].to_s }
    end
  end
end
