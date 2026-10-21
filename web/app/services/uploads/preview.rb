# frozen_string_literal: true

module Uploads
  # What the detail page shows of a file: the first rows or lines, as plain data.
  # Cells are returned as text for the view to escape; nothing is evaluated.
  module Preview
    Result = Struct.new(:kind, :rows, :header_index, :lines, :outline, :notes, :sheets, :truncated, keyword_init: true)

    def self.build(document, importer = nil)
      custom = importer&.new&.preview(document)
      return custom if custom

      notes = []
      notes << "Read as #{document.encoding}." if document.encoding && document.encoding != 'UTF-8'
      case document.format
      when 'csv', 'xlsx' then table(document, notes)
      when 'text' then Result.new(kind: :lines, lines: document.text_lines, notes: notes, truncated: (document.line_count || 0) > 40)
      when 'json'
        Result.new(kind: :lines, lines: document.text_lines, outline: document.json_outline, notes: notes, truncated: (document.line_count || 0) > 40 || document.bytes.bytesize > 4096)
      else
        Result.new(kind: :none, notes: ['Rupert does not open PDF files. The original is kept unchanged; download it to read it.'])
      end
    end

    def self.table(document, notes)
      rows = document.rows(Limits::PREVIEW_ROWS)
      notes << "Workbook sheets: #{document.sheets.join(', ')}. Only the first sheet is shown." if document.sheets.size > 1
      notes << 'This workbook contains macros. Rupert never runs them.' if document.macros?
      notes << 'Excel dates appear as serial numbers and formulas as their last saved value.' if document.format == 'xlsx'
      notes << "Fields are separated by “#{document.delimiter == "\t" ? 'tab' : document.delimiter}”." if document.format == 'csv' && document.delimiter != ','
      Result.new(kind: :table, rows: rows.map { |row| row.first(Limits::PREVIEW_COLS) }, header_index: document.header_index, notes: notes,
        truncated: (document.line_count || rows.size) > rows.size || rows.any? { |row| row.size > Limits::PREVIEW_COLS })
    end
  end
end
