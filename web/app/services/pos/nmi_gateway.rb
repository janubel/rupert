# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'nokogiri'

module Pos
  # Deliberately sandbox-only. No production endpoint or runtime override exists.
  # NMI contracts: payment-code-examples (REST sale), query (Classic reporting).
  class NmiGateway
    SALE_URL = 'https://sandbox.nmi.com/api/v5/payments/sale'
    QUERY_URL = 'https://sandbox.nmi.com/api/query.php'
    SCRIPT_URL = 'https://sandbox.nmi.com/token/Collect.js'
    MAX_BYTES = 512 * 1024
    attr_reader :version

    def initialize(setting)
      raise Error, 'NMI production payments are disabled pending Next Stage confirmation.' unless setting.nmi_sandbox?
      raise Error, 'Gateway belongs to another workspace.' unless setting.persisted? && setting.tenant_id == Current.tenant_id
      @setting = setting
      @version = setting.lock_version
      @credentials = setting.credentials
      unless %w[security_key tokenization_key merchant_company].all? { |key| @credentials[key].is_a?(String) && @credentials[key].present? }
        raise Error, 'Save dedicated NMI sandbox keys and the expected sandbox company first.'
      end
      @fingerprint = setting.payment_fingerprint
    end

    def assert_checkout!(checkout)
      unless checkout.tenant_id == Current.tenant_id && checkout.location_id == @setting.location_id &&
          checkout.sandbox_payment? && checkout.gateway_id == @setting.gateway_id &&
          checkout.gateway_fingerprint == @fingerprint
        raise Error, 'NMI sandbox account changed. Review the original payment setup.'
      end
    end

    def merchant
      doc = query(report_type: 'profile')
      names = doc.xpath('/nm_response/merchant/company')
      unless names.one? && names.first.element_children.empty? && names.first.text == @credentials.fetch('merchant_company')
        raise Error, 'NMI sandbox merchant company did not match. No payment was sent.'
      end
      # The profile contract has no Gateway ID. Do not claim that it verifies one.
      { 'publicClientKey' => @credentials.fetch('tokenization_key') }
    end

    def charge(attempt, token)
      checkout = attempt.pos_checkout
      assert_checkout!(checkout)
      payload = { amount: format('%.2f', BigDecimal(checkout.total_cents.to_s) / 100), currency: 'USD',
        payment_details: { payment_token: token },
        order_details: { id: attempt.invoice, order_description: 'Rupert sandbox checkout' } }
      req = Net::HTTP::Post.new(URI(SALE_URL).request_uri,
        'Authorization' => @credentials.fetch('security_key'), 'Content-Type' => 'application/json', 'Accept' => 'application/json')
      req.body = JSON.generate(payload)
      doc = JSON.parse(request(SALE_URL, req), max_nesting: 30)
      raise Error, 'NMI sandbox response could not be verified. Check payment status before retrying.' unless doc.is_a?(Hash)
      # Keep card/customer data, vendor error text and raw responses out of storage/errors.
      doc.slice('id', 'response')
    rescue JSON::ParserError, EncodingError
      raise Error, 'NMI sandbox response could not be verified. Check payment status before retrying.'
    end

    def transaction(attempt)
      params = { report_type: 'transaction', order_id: attempt.invoice }
      params[:transaction_id] = attempt.transaction_id if attempt.transaction_id.present?
      rows = query(**params).xpath('/nm_response/transaction')
      raise Error, 'Multiple NMI payments need review; no new charge was sent.' if rows.size > 1
      return if rows.empty?

      row = rows.first
      values = %w[transaction_id transaction_type condition order_id currency].to_h do |key|
        nodes = row.xpath("./#{key}")
        raise Error, 'NMI sandbox transaction data is ambiguous.' unless nodes.one? && nodes.first.element_children.empty?
        [key, nodes.first.text]
      end
      values['actions'] = row.xpath('./action').map do |action|
        %w[action_type success amount].to_h do |key|
          nodes = action.xpath("./#{key}")
          raise Error, 'NMI sandbox action data is ambiguous.' unless nodes.one? && nodes.first.element_children.empty?
          [key, nodes.first.text]
        end
      end
      values
    end

    private

    def query(**fields)
      req = Net::HTTP::Post.new(URI(QUERY_URL).request_uri, 'Accept' => 'application/xml')
      req.set_form_data(fields.merge(security_key: @credentials.fetch('security_key')))
      body = request(QUERY_URL, req).force_encoding(Encoding::UTF_8)
      raise Error, 'NMI sandbox report could not be verified.' unless body.valid_encoding? && !body.match?(/<!\s*(?:DOCTYPE|ENTITY)\b/i)
      doc = Nokogiri::XML(body, nil, 'UTF-8') { |config| config.strict.nonet }
      unless doc.root&.name == 'nm_response' && doc.root.namespace.nil? && !doc.internal_subset &&
          doc.xpath('//error | //error_response').empty?
        raise Error, 'NMI sandbox report could not be verified.'
      end
      doc
    rescue Nokogiri::XML::SyntaxError, EncodingError
      raise Error, 'NMI sandbox report could not be verified.'
    end

    def request(url, req)
      uri = URI(url)
      # Fixed sandbox hosts, no proxies, redirects, retries or raw response logging.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 10
      http.write_timeout = 5
      http.max_retries = 0
      req['Accept-Encoding'] = 'identity'
      body = +''
      http.start do |session|
        session.request(req) do |response|
          raise Error, 'NMI sandbox response could not be verified. Check payment status before retrying.' unless response.code == '200'
          response.read_body do |chunk|
            raise Error, 'NMI sandbox response exceeded its limit.' if body.bytesize + chunk.bytesize > MAX_BYTES
            body << chunk
          end
        end
      end
      body
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError
      raise Error, 'NMI sandbox outcome is unknown. Check payment status before retrying.'
    end
  end
end
