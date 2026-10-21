# frozen_string_literal: true

module Uploads
  # Turns uploaded text bytes into UTF-8 for sniffing and preview only. The
  # original bytes are never rewritten. Binary data is refused rather than guessed.
  module TextDecoder
    Decoded = Struct.new(:text, :encoding, keyword_init: true)

    def self.decode(bytes)
      data = bytes.to_s.b
      if data.start_with?("\xEF\xBB\xBF".b)
        utf8(data.byteslice(3..), 'UTF-8 (BOM)')
      elsif data.start_with?("\xFF\xFE".b)
        utf16(data.byteslice(2..), 'UTF-16LE', 'UTF-16 LE (BOM)')
      elsif data.start_with?("\xFE\xFF".b)
        utf16(data.byteslice(2..), 'UTF-16BE', 'UTF-16 BE (BOM)')
      elsif data.include?("\x00".b)
        nil
      else
        utf8(data, 'UTF-8') || windows(data)
      end
    end

    def self.utf8(data, label)
      text = data.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? && textual?(text) ? Decoded.new(text: text, encoding: label) : nil
    end

    def self.utf16(data, encoding, label)
      text = data.dup.force_encoding(encoding).encode(Encoding::UTF_8)
      textual?(text) ? Decoded.new(text: text, encoding: label) : nil
    rescue EncodingError
      nil
    end

    # Bank and accounting exports from older Windows software. Assumed, and
    # labelled as assumed so the operator can see it.
    def self.windows(data)
      text = data.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
      textual?(text) ? Decoded.new(text: text, encoding: 'Windows-1252 (assumed)') : nil
    rescue EncodingError
      nil
    end

    # A real text file has almost no control characters besides tab and newlines.
    def self.textual?(text)
      sample = text.first(65_536)
      return true if sample.empty?

      controls = sample.count("\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F")
      controls * 100 <= sample.length
    end
  end
end
