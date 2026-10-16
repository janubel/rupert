# frozen_string_literal: true

module Marketing
  module Urls
    def self.valid?(value)
      uri = URI.parse(value.to_s)
      return false unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.port == 443
      return false unless uri.host.match?(/\A[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?)+\z/i)
      return false if uri.host.match?(/(?:\A|\.)(localhost|local|internal|test|invalid|example)\z/i)
      return false if uri.host.match?(/\A[\d.]+\z/)

      value.to_s.length <= 2000 && !value.to_s.match?(/[\s\\]/)
    rescue URI::InvalidURIError
      false
    end

    def self.host(value)
      URI.parse(value.to_s).host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    def self.canonical(value)
      return value unless valid?(value)

      uri = URI.parse(value)
      uri.host = uri.host.downcase
      uri.fragment = nil
      uri.path = uri.path.sub(%r{/+\z}, '')
      # Some forums identify discussions through ?id=; keep identity parameters.
      pairs = URI.decode_www_form(uri.query.to_s).reject do |key, _|
        key.start_with?('utm_') || %w[fbclid gclid ref share_id].include?(key)
      end
      pairs = [] if uri.host == 'reddit.com' || uri.host.end_with?('.reddit.com')
      uri.query = pairs.empty? ? nil : URI.encode_www_form(pairs.sort)
      uri.to_s
    end
  end
end
