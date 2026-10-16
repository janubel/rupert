# frozen_string_literal: true

require 'net/http'

module Marketing
  # A captured, tenant-specific connection. No global store fallback, token cache,
  # redirects or automatic mutation retries. Errors never include HTTP bodies.
  class ShopifyDiscountApi
    class Error < ReplyWorkflow::Invalid; end
    class Rejected < Error; end
    QUERIES = %w[shop create lookup].to_h do |name|
      [name, Rails.root.join("app/graphql/marketing/discount_#{name}.graphql").read.freeze]
    end.freeze
    attr_reader :shop_domain

    def initialize
      raise Error, 'Choose an active workspace first.' unless Current.tenant&.status == 'active'

      EnvStore.clear_cache!
      @shop_domain = EnvStore.fetch('SHOPIFY_SHOP_DOMAIN', '').to_s.strip.downcase
      @client_id = EnvStore.fetch('SHOPIFY_CLIENT_ID', '').to_s
      @client_secret = EnvStore.fetch('SHOPIFY_CLIENT_SECRET', '').to_s
      unless @shop_domain.match?(/\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z/) && @client_id.present? && @client_secret.present?
        raise Error, 'Save this workspace’s Shopify store domain and client credentials in Connections first.'
      end
    end

    def shop
      data = graphql('shop')
      scopes = data.dig('currentAppInstallation', 'accessScopes').to_a.pluck('handle')
      unless scopes.include?('write_discounts')
        raise Error, 'The Shopify app needs write_discounts access. Grant it in Shopify and reconnect before creating codes.'
      end

      shop = data.fetch('shop')
      unless shop['myshopifyDomain'] == shop_domain && shop['id'].to_s.match?(%r{\Agid://shopify/Shop/\d+\z}) &&
          shop['currencyCode'].to_s.match?(/\A[A-Z]{3}\z/) && Urls.valid?(shop.dig('primaryDomain', 'url'))
        raise Error, 'Shopify store identity could not be verified.'
      end
      shop
    rescue KeyError, NoMethodError, TypeError
      raise Error, 'Shopify store identity could not be verified.'
    end

    def lookup(code)
      data = graphql('lookup', { code: code })
      raise Error, 'Shopify returned an incomplete code lookup.' unless data.key?('codeDiscountNodeByCode')

      data['codeDiscountNodeByCode']
    end

    def create(input)
      PlatformPushGuard.authorize!('shopify', actor: Current.user&.email || 'discount operator')
      result = graphql('create', { input: input }).fetch('discountCodeBasicCreate')
      if result['userErrors'].present? && result['codeDiscountNode'].blank?
        raise Rejected, 'Shopify rejected these offer terms or this code already exists. Check Shopify before drafting a replacement.'
      end
      id = result.dig('codeDiscountNode', 'id')
      unless result['userErrors'] == [] && id.to_s.match?(%r{\Agid://shopify/DiscountCodeNode/\d+\z})
        raise Error, 'Shopify’s creation result is uncertain. Check the result before trying another code.'
      end
      id
    rescue KeyError, NoMethodError, TypeError
      raise Error, 'Shopify’s creation result is uncertain. Check the result before trying another code.'
    end

    private

    def graphql(operation, variables = {})
      @token ||= post('/admin/oauth/access_token', { client_id: @client_id, client_secret: @client_secret, grant_type: 'client_credentials' }).fetch('access_token')
      raise Error, 'Shopify authentication failed. Check the connection credentials.' if @token.blank?

      result = post("/admin/api/#{ShopifyClient::API_VERSION}/graphql.json", { query: QUERIES.fetch(operation), variables: variables }, @token)
      raise Error, 'Shopify could not complete this request. Check the app’s access and connection, then check the code result.' if result['errors'].present?

      data = result.fetch('data')
      raise Error, 'Shopify returned an incomplete response.' unless data.is_a?(Hash)

      data
    rescue KeyError
      raise Error, 'Shopify returned an incomplete response. Check the connection and code result.'
    end

    def post(path, body, token = nil)
      uri = URI("https://#{shop_domain}#{path}")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['X-Shopify-Access-Token'] = token if token
      request.body = JSON.generate(body)
      http = Net::HTTP.new(uri.host, 443)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = http.write_timeout = 30
      http.max_retries = 0
      response = http.start { |connection| connection.request(request) }
      raise Error, 'Shopify is unavailable or denied access. Check the connection and code result.' unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      raise Error, 'Shopify returned an invalid response. Check the code result.' unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      raise Error, 'Shopify did not return a reliable response. Check the code result before trying another code.'
    end
  end
end
