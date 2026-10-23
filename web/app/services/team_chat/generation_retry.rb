# frozen_string_literal: true

require 'time'

module TeamChat
  # Only explicit transient HTTP refusals, never ambiguous network failures.
  module GenerationRetry
    STATUSES = [429, 500, 502, 503, 504, 529].freeze
    MAX_DELAY = 5.0
    DEFAULT_DELAY = 0.5

    def self.delay(error)
      response = error.response
      return unless response && STATUSES.include?(response.status)

      headers = response.respond_to?(:response_headers) ? response.response_headers : response.headers
      value = headers&.[]('retry-after').to_s.strip
      delay = if value.empty?
        DEFAULT_DELAY
      elsif value.match?(/\A\d+\z/)
        value.to_i.to_f
      else
        [Time.httpdate(value) - Time.current, 0].max
      end
      delay if delay <= MAX_DELAY
    rescue ArgumentError
      # A malformed provider hint does not justify ignoring a requested delay.
      nil
    end
  end
end
