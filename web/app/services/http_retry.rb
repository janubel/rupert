# frozen_string_literal: true

require 'net/http'

# Bounded retry with exponential backoff and jitter for the platform clients.
# Retries only what is safe and useful to retry: rate limits (429 / Shopify
# THROTTLED), 5xx, and connection-level failures. Credential, permission and
# contract errors are raised immediately. Retry-After (seconds) is honoured
# when the vendor sends one. Mutations through these clients carry
# idempotency keys, so a retry after a lost response cannot double-apply.
module HttpRetry
  MAX_ATTEMPTS = 4
  BASE_DELAY = 1.0
  MAX_DELAY = 30.0
  NETWORK_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
    EOFError, OpenSSL::SSL::SSLError, SocketError].freeze

  class Retry < StandardError
    attr_reader :after

    def initialize(message, after: nil)
      @after = after
      super(message)
    end
  end

  # How to wait between attempts. Never sleeps in the test environment;
  # HttpRetryTest swaps in a recorder to assert the delays. (Kept lazy so the
  # file is not loaded before the parallel test workers fork, which would
  # reset its coverage.)
  mattr_accessor :sleeper, default: (Rails.env.test? ? ->(_seconds) {} : Kernel.method(:sleep))

  class << self
    # Yields the attempt number (1-based). The block raises HttpRetry::Retry to
    # ask for another attempt; anything else propagates. After the last
    # attempt the Retry's cause (the real error) is raised.
    def with_retries(label, max_attempts: MAX_ATTEMPTS, sleeper: self.sleeper)
      attempt = 0
      begin
        attempt += 1
        yield(attempt)
      rescue Retry => e
        raise e.cause || e if attempt >= max_attempts

        delay = e.after || backoff(attempt)
        Rails.logger.warn("[#{label}] attempt #{attempt}/#{max_attempts} will retry in #{delay.round(1)}s: #{e.message}")
        sleeper.call(delay)
        retry
      end
    end

    def backoff(attempt)
      base = [BASE_DELAY * (2**(attempt - 1)), MAX_DELAY].min
      base + (rand * base * 0.25)
    end

    def retry_after(response)
      value = response['Retry-After'].to_s
      return nil if value.blank?

      seconds = value.match?(/\A\d+(\.\d+)?\z/) ? value.to_f : (Time.httpdate(value) - Time.now rescue nil)
      seconds&.clamp(0.5, 120.0)
    end

    def retryable_status?(code)
      code = code.to_i
      code == 429 || code >= 500
    end
  end
end
