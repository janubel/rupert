# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'

module Uploads
  # A read-only view of one upload's bytes for importers to sniff and preview.
  # It decodes and samples; it never writes, executes or follows anything inside
  # the file. Heavy work is lazy and memoized.
  class Document
    DELIMITERS = [',', "\t", ';', '|'].freeze

    attr_reader :bytes, :filename, :format

    def initialize(bytes:, filename:, format:)
      @bytes = bytes.b.freeze
      @filename = filename.to_s
      @format = format
    end

    def self.for(upload)
      new(bytes: upload.original_bytes, filename: upload.filename, format: upload.file_format)
    end

    def sha256 = @sha256 ||= Digest::SHA256.hexdigest(@bytes)

    def textual? = %w[csv text json].include?(format)

    def decoded = @decoded ||= (textual? ? TextDecoder.decode(@bytes) : nil)

    # UTF-8, BOM removed, UTF-16 converted. What importers are given.
    def text = decoded&.text

    def encoding = decoded&.encoding

    def line_count
      return nil unless text && %w[csv text].include?(format)

      @line_count ||= text.each_line.count { |line| !line.strip.empty? }
    end

    def delimiter
      @delimiter ||= begin
        lines = text.to_s.each_line.reject { |line| line.strip.empty? }.first(20)
        scored = DELIMITERS.map do |candidate|
          counts = lines.map { |line| line.count(candidate) }.select(&:positive?)
          mode = counts.tally.max_by { |_, times| times }
          [candidate, mode ? mode[1] * mode[0] : 0]
        end
        best = scored.max_by(&:last)
        best.last.positive? ? best.first : ','
      end
    end

    # First rows as arrays of strings (cells trimmed of the BOM only).
    def rows(limit = Limits::SAMPLE_ROWS)
      @rows ||= {}
      @rows[limit] ||= case format
      when 'csv', 'text' then csv_rows(limit)
      when 'xlsx' then xlsx_rows(limit)
      else []
      end
    end

    def sheets
      xlsx&.sheets&.map(&:name) || []
    end

    def macros? = !!xlsx&.macros?

    # Index (into rows) of the row that looks like the column headings. Titles
    # and filter notes above it are common in accounting exports.
    def header_index
      @header_index ||= begin
        found = rows(40).each_with_index.find do |row, index|
          cells = row.map { |cell| cell.to_s.strip }.reject(&:empty?)
          cells.size >= 2 && cells.size >= row.size * 0.5 && cells.none? { |cell| cell.length > 80 } &&
            cells.count { |cell| cell.match?(/\A[\d.,$()\-\/: ]+\z/) } * 2 < cells.size && rows(40)[index + 1]
        end
        found ? found.last : 0
      end
    end

    # Heading cells, lower-cased and squished.
    def header
      @header ||= (rows(40)[header_index] || []).map { |cell| self.class.norm(cell) }
    end

    def body_rows(limit = Limits::SAMPLE_ROWS)
      rows(limit)[(header_index + 1)..] || []
    end

    def preamble
      rows(40).first(header_index)
    end

    def self.norm(value)
      value.to_s.downcase.gsub(/\s+/, ' ').strip
    end

    # Normalised heading cells with everything but letters and digits removed.
    def header_keys
      @header_keys ||= header.map { |cell| cell.gsub(/[^a-z0-9]/, '') }
    end

    def json
      return @json if defined?(@json)

      @json = if format == 'json' && text && text.bytesize <= Limits::JSON_MAX_BYTES
        begin
          JSON.parse(text, max_nesting: 20)
        rescue JSON::ParserError, JSON::NestingError
          nil
        end
      end
    end

    # A short, escaped-by-the-view description of what a JSON document holds.
    def json_outline
      value = json
      case value
      when Array then "A list of #{value.size} item#{'s' unless value.size == 1}#{value.first.is_a?(Hash) ? ", each with: #{value.first.keys.first(12).join(', ')}" : ''}"
      when Hash then "An object with: #{value.keys.first(20).join(', ')}"
      when nil then 'Not readable as JSON'
      else "A single #{value.class.name.downcase} value"
      end
    end

    def text_lines(limit = 40)
      text.to_s.each_line.first(limit).map { |line| line.chomp.first(Limits::PREVIEW_CELL * 2) }
    end

    private

    def xlsx
      return @xlsx if defined?(@xlsx)

      @xlsx = format == 'xlsx' ? XlsxReader.new(@bytes) : nil
    rescue ZipInspector::Error
      @xlsx = nil
    end

    def xlsx_rows(limit)
      xlsx&.rows(limit: limit) || []
    rescue ZipInspector::Error
      []
    end

    def csv_rows(limit)
      return [] unless text

      if format == 'text'
        return text.each_line.first(limit).map { |line| [line.chomp] }
      end

      out = []
      CSV.new(text, col_sep: delimiter, liberal_parsing: true, field_size_limit: 100_000).each do |row|
        out << row.map { |cell| cell.to_s }
        break if out.size >= limit
      end
      out
    rescue CSV::MalformedCSVError, ArgumentError
      text.each_line.first(limit).map { |line| line.chomp.split(delimiter, -1) }
    end
  end
end
