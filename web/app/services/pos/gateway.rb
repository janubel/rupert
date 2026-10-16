# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
module Pos
  class Gateway
    ENDPOINTS = { 'sandbox' => 'https://apitest.authorize.net/xml/v1/request.api', 'production' => 'https://api.authorize.net/xml/v1/request.api' }.freeze
    MAX_BYTES = 2 * 1024 * 1024
    attr_reader :setting, :version

    def initialize(setting)
      raise Error, 'Gateway belongs to another workspace.' unless setting.persisted? && setting.tenant_id == Current.tenant_id
      @setting = setting
      @version = setting.lock_version
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
      @bytes = 0
      @credentials = setting.credentials
      raise Error, 'Save the gateway API Login ID and Transaction Key first.' unless %w[api_login_id transaction_key].all? { |key| @credentials[key].present? }
    end

    def merchant
      row = request('getMerchantDetailsRequest')
      raise Error, 'This is not the configured gateway account.' unless row['gatewayId'].to_s == setting.gateway_id && row['gatewayId'].to_s.match?(/\A[1-9][0-9]{0,29}\z/)
      raise Error, 'Gateway must accept USD and have a public client key.' unless row['currencies'].is_a?(Array) && row['currencies'].include?('USD') && row['publicClientKey'].is_a?(String) && row['publicClientKey'].match?(/\A[[:graph:]]{1,128}\z/)
      raise Error, 'Production gateway is in test mode.' if setting.environment == 'production' && row['isTestMode'] != false
      row
    end

    def charge(attempt, nonce)
      checkout = attempt.pos_checkout
      request('createTransactionRequest', refId: attempt.invoice, transactionRequest: {
        transactionType: 'authCaptureTransaction', amount: decimal(checkout.total_cents),
        payment: { opaqueData: { dataDescriptor: 'COMMON.ACCEPT.INAPP.PAYMENT', dataValue: nonce } },
        order: { invoiceNumber: attempt.invoice, description: 'Rupert retail checkout' },
        tax: { amount: decimal(checkout.tax_cents), name: 'Sales tax' },
        transactionSettings: { setting: [{ settingName: 'duplicateWindow', settingValue: '28800' }] }
      }, transaction: true)
    end

    def detail(id)
      raise Error, 'Invalid gateway transaction reference.' unless id.to_s.match?(/\A[1-9][0-9]{0,29}\z/)
      row = request('getTransactionDetailsRequest', transId: id)['transaction']
      raise Error, 'Gateway returned mismatched transaction details.' unless row.is_a?(Hash) && row['transId'].to_s == id.to_s
      row
    end

    def find_transaction(invoice, since:)
      results = []
      pages('getUnsettledTransactionListRequest').each { |row| results << row if row['invoiceNumber'] == invoice }
      batches = request('getSettledBatchListRequest', firstSettlementDate: since.utc.iso8601, lastSettlementDate: Time.current.utc.iso8601)['batchList'] || []
      raise Error, 'Gateway batch list is incomplete.' unless batches.is_a?(Array) && batches.size <= 100
      batches.each do |batch|
        pages('getTransactionListRequest', batchId: batch.fetch('batchId')).each { |row| results << row if row['invoiceNumber'] == invoice }
      end
      results.uniq! { |row| row['transId'] }
      raise Error, 'Multiple payments need review; no new charge was sent.' if results.size > 1
      results.first && detail(results.first.fetch('transId'))
    end

    def decimal(cents) = (BigDecimal(cents.to_s) / 100).to_s('F')

    private

    def pages(method, **fields)
      rows = []
      total = nil
      20.times do |index|
        doc = request(method, **fields, paging: { limit: 1000, offset: index + 1 })
        page = doc['transactions'] || []
        count = doc['totalNumInResultSet']
        raise Error, 'Gateway transaction pages are incomplete.' unless page.is_a?(Array) && page.all? { |row| row.is_a?(Hash) } && count.to_s.match?(/\A[0-9]{1,5}\z/)
        total ||= count.to_i
        raise Error, 'Gateway transaction pages changed.' unless total == count.to_i
        rows.concat(page)
        if rows.size == total
          raise Error, 'Gateway transaction pages repeated.' unless rows.pluck('transId').uniq.size == rows.size
          return rows
        end
      end
      raise Error, 'Gateway transaction page limit exceeded.'
    end

    def request(method, transaction: false, **fields)
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error, 'Gateway verification exceeded its time limit.' if remaining <= 0
      uri = URI(ENDPOINTS.fetch(setting.environment))
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = [3, remaining].min
      http.read_timeout = [15, remaining].min
      http.write_timeout = [5, remaining].min
      http.max_retries = 0
      req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      req.body = JSON.generate(method => { merchantAuthentication: { name: @credentials.fetch('api_login_id'), transactionKey: @credentials.fetch('transaction_key') } }.merge(fields))
      body = +''
      http.start do |session|
        session.request(req) do |response|
          raise Error, 'Gateway response could not be verified.' unless response.code == '200'
          response.read_body { |chunk|
            @bytes += chunk.bytesize
            body << chunk
            raise Error, 'Gateway response exceeded its limit.' if body.bytesize > MAX_BYTES || @bytes > 8 * MAX_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline }
        end
      end
      doc = JSON.parse(body.b.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8), max_nesting: 30, decimal_class: BigDecimal)
      raise Error, 'Gateway response could not be verified.' unless doc.is_a?(Hash) && (transaction || doc.dig('messages', 'resultCode') == 'Ok')
      doc
    rescue JSON::ParserError, KeyError, TypeError, EncodingError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      raise Error, 'Gateway outcome could not be verified. Check payment status before retrying.'
    end
  end
end
