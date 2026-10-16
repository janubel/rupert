# frozen_string_literal: true

module Marketing
  module ReferralUrl
    def self.build(destination, source:, campaign:, content:)
      uri = URI.parse(destination)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key.start_with?('utm_') }
      query.concat([['utm_source', source], ['utm_medium', 'influencer'],
                    ['utm_campaign', "campaign-#{campaign}"], ['utm_content', content]])
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end
  end
end
