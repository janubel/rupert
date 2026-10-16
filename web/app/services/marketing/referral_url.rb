# frozen_string_literal: true

module Marketing
  module ReferralUrl
    def self.build(destination, source:, campaign:, content:, discount_code: nil)
      uri = URI.parse(destination)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key.start_with?('utm_') || (discount_code && key == 'discount') }
      query.concat([['utm_source', source], ['utm_medium', 'influencer'],
                    ['utm_campaign', "campaign-#{campaign}"], ['utm_content', content]])
      uri.query = URI.encode_www_form(query)
      if discount_code
        raise ReplyWorkflow::Invalid, 'Use a storefront page with an ordinary relative path.' if uri.path.match?(%r{\A/(?:/|%2f|%5c)}i)

        redirect = uri.request_uri
        redirect += "##{uri.fragment}" if uri.fragment
        uri.path = "/discount/#{ERB::Util.url_encode(discount_code)}"
        uri.fragment = nil
        uri.query = URI.encode_www_form([['redirect', redirect]])
      end
      uri.to_s
    end
  end
end
