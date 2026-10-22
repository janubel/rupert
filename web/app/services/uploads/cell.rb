# frozen_string_literal: true

module Uploads
  # Cell values from an uploaded file are text, never formulas. Views escape them
  # (ERB does that) and mark the dangerous-looking ones; anything that leaves
  # Rupert as CSV or JSON goes through `neutralize`, which defuses a leading
  # = + - @ tab or carriage return the way spreadsheet security guidance asks.
  module Cell
    FORMULA_START = /\A[=+\-@\t\r]/
    PLAIN_NUMBER = /\A[+-]?\s*[$(]?\d[\d,]*(\.\d+)?\)?\z/

    def self.display(value, max: Limits::PREVIEW_CELL)
      text = value.to_s.scrub('?').gsub(/[\u0000-\u0008\u000B-\u001F\u007F‪-‮⁦-⁩]/, ' ')
      text.length > max ? "#{text.first(max)}…" : text
    end

    def self.formula_like?(value)
      text = value.to_s
      text.match?(FORMULA_START) && !text.match?(PLAIN_NUMBER)
    end

    def self.neutralize(value)
      text = value.to_s
      text.match?(FORMULA_START) ? "'#{text}" : text
    end
  end
end
