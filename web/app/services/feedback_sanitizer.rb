# frozen_string_literal: true

# Scrubs text that goes into a report's diagnostics. Parameter names are judged
# by the same filter the request log uses (config/initializers/filter_parameters
# .rb), so a new filtered key is covered here without a second list.
module FeedbackSanitizer
  FILTERED = '[FILTERED]'
  PAIR = /(["']?)([A-Za-z][\w\[\].-]{0,60})\1(\s*[=:]\s*)("[^"]{0,500}"|'[^']{0,500}'|[^\s&,;}\])"']+)/
  SECRET_TOKEN = /\brupert_[A-Za-z0-9_-]{20,}|\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/i
  QUOTED = /'(?:[^']|'')*'/
  NUMBER = /(?<![\w"`.])\d+(?:\.\d+)?(?![\w"`])/

  module_function

  def parameter_filter
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  def filtered_key?(filter, key)
    filter.filter(key => 'x')[key] == FILTERED
  end

  # key=value, "key":"value" and key: value pairs whose key the log filter hides,
  # plus bearer tokens and Rupert API tokens wherever they appear.
  def scrub_text(text, max: nil)
    out = scrub_pairs(text.to_s.scrub('').gsub(SECRET_TOKEN, FILTERED), parameter_filter)
    max ? out.first(max) : out
  end

  # A quoted value that is itself text (a JSON message, a log line) is scanned for pairs too.
  def scrub_pairs(text, filter)
    text.gsub(PAIR) do
      quote = Regexp.last_match(1)
      key = Regexp.last_match(2)
      separator = Regexp.last_match(3)
      value = Regexp.last_match(4)
      if filtered_key?(filter, key)
        "#{quote}#{key}#{quote}#{separator}#{FILTERED}"
      elsif value.start_with?('"', "'") && value.length > 2
        "#{quote}#{key}#{quote}#{separator}#{value[0]}#{scrub_pairs(value[1..-2], filter)}#{value[-1]}"
      else
        Regexp.last_match(0)
      end
    end
  end

  # Literal values never leave the server: strings and numbers become ?.
  def scrub_sql(sql, max: nil)
    out = sql.to_s.scrub('').gsub(QUOTED, "'?'").gsub(NUMBER, '?').squish
    max ? out.first(max) : out
  end

  # A page address becomes its path plus the query with filtered values hidden; the host
  # is Rupert's own and the fragment is dropped.
  def scrub_url(url, max: 500)
    uri = URI.parse(url.to_s.strip)
    query = uri.query.present? ? parameter_filter.filter(Rack::Utils.parse_query(uri.query)).to_query : nil
    "#{uri.path.presence || '/'}#{"?#{query}" if query.present?}".first(max)
  rescue URI::InvalidURIError
    nil
  end
end
