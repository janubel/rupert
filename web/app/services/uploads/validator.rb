# frozen_string_literal: true

module Uploads
  # Decides whether the bytes really are what the extension claims, before a file
  # is kept. A refusal is a plain-language reason shown to the person and logged
  # as an outcome. Nothing here opens, runs or follows anything in the file.
  module Validator
    CODES = { 'csv' => 'not_text', 'text' => 'not_text', 'json' => 'bad_json', 'pdf' => 'bad_pdf', 'xlsx' => 'bad_xlsx' }.freeze

    # The plain-language reason a file cannot be kept, or nil when it is sound.
    def self.check(bytes, format)
      problem(bytes, format)&.last
    end

    # [reason_code, message] or nil.
    def self.problem(bytes, format)
      message = case format
      when 'csv', 'text' then text_reason(bytes, format)
      when 'json' then json_reason(bytes)
      when 'pdf' then bytes.byteslice(0, 1024).to_s.b.include?('%PDF-'.b) ? nil : 'This does not look like a PDF (no PDF header).'
      when 'xlsx' then xlsx_reason(bytes)
      else "Unsupported file type. Send #{Limits::FORMATS.keys.to_sentence(last_word_connector: ', or ')}."
      end
      message && [CODES.fetch(format, 'unsupported_type'), message]
    end

    def self.text_reason(bytes, format)
      return nil if TextDecoder.decode(bytes)

      "This does not look like a #{format == 'csv' ? 'CSV' : 'text'} file: it contains binary data or an unreadable text encoding. Export it again as UTF-8 text."
    end

    def self.json_reason(bytes)
      decoded = TextDecoder.decode(bytes) or return 'This does not look like a JSON file: it contains binary data or an unreadable text encoding.'
      return nil if decoded.text.bytesize > Limits::JSON_MAX_BYTES # too large to parse here; kept as text

      JSON.parse(decoded.text, max_nesting: 20)
      nil
    rescue JSON::ParserError, JSON::NestingError
      'This is not valid JSON.'
    end

    def self.xlsx_reason(bytes)
      XlsxReader.new(bytes)
      nil
    rescue ZipInspector::Error => e
      e.message
    end
  end
end
