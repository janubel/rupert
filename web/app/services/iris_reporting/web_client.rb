# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'nokogiri'

module IrisReporting
  # Website export flow, not the published REST API. Own ephemeral login only.
  class WebClient
    ORIGIN = 'https://nabankco.iriscrm.com'
    MAX_BYTES = 4 * 1024 * 1024
    IDENTITY_QUERY = 'query RupertMerchant($mid: String) { merchants(mid: $mid) { total data { mid } } }'
    READ_QUERY = <<~GRAPHQL
      query RupertDailyDeposits($mid: String, $year: Int, $month: Int, $batches: BatchesTypeEnum) {
        merchantDailyDeposits(mid: $mid, year: $year, month: $month, batches: $batches, export: false) {
          data { date amount transactions reference_number terminal_number type }
          total { amount transactions }
        }
      }
    GRAPHQL
    EXPORT_QUERY = <<~GRAPHQL
      query MerchantDailyDeposits($mid: String, $year: Int, $month: Int, $batches: BatchesTypeEnum,
        $exportType: String, $exportFileName: String, $exportTitle: String) {
        merchantDailyDeposits(mid: $mid, year: $year, month: $month, batches: $batches, export: true,
          export_type: $exportType, export_file_name: $exportFileName, export_header: $exportTitle, export_add_numbers: false) {
          data { date amount transactions reference_number terminal_number type }
          exportUrl: export_url
        }
      }
    GRAPHQL
    Snapshot = Struct.new(:merchant, :period, :text, :rows, keyword_init: true)

    class Error < StandardError
      MESSAGES = {
        invalid: 'Save the authorized NAB website login and numeric merchant IDs.',
        login: 'NAB website sign-in failed. Automatic deposits are paused; check the saved login.',
        verification: 'NAB requires additional sign-in verification. Automatic deposits are paused.',
        identity: 'NAB did not confirm the requested merchant. Previous deposit reports were retained.',
        response: 'NAB changed its website response or returned an incomplete export. Previous deposit reports were retained.',
        network: 'NAB could not be reached securely. Previous deposit reports were retained.',
        limit: 'NAB deposits exceeded the supported size or time limit. Previous reports were retained.',
        changed: 'NAB setup changed during the pull. Nothing was imported.'
      }.freeze
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(MESSAGES.fetch(reason))
      end

      def login_required?
        %i[login verification].include?(reason)
      end
    end

    def self.valid_credentials?(values)
      values.is_a?(Hash) && %w[web_username web_password].all? do |key|
        value = values[key]
        value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 4096) && !value.match?(/[\x00-\x1f\x7f]/)
      end && !values['web_username'].match?(/\s/)
    end

    def initialize(credentials)
      raise Error, :invalid unless self.class.valid_credentials?(credentials)

      @credentials = credentials
      @cookies = {}
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      @bytes = 0
    end

    def fetch(merchants:, months:)
      raise Error, :invalid unless merchants.is_a?(Array) && Client.merchants(merchants.join(',')) == merchants &&
        months.is_a?(Array) && months.size.between?(1, 2) && months.uniq == months && months.all? { |date| date.is_a?(Date) && date.day == 1 }

      login!
      merchants.flat_map do |mid|
        identity = graphql(IDENTITY_QUERY, { mid: mid }).fetch('merchants')
        raise Error, :identity unless identity.is_a?(Hash) && identity['total'].to_i == 1 && identity['data'].is_a?(Array) && identity['data'].map { |row| row['mid'].to_s } == [mid]

        months.map { |month| export(mid, month) }
      end
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, URI::InvalidURIError, EncodingError
      raise Error.new(:response), cause: nil
    end

    private

    def login!
      page = get('/v2/login?ref=%2Fmerchant-portal')
      @csrf = csrf_from(page.body)
      req = Net::HTTP::Post.new('/v2/login')
      req.set_form([['username', @credentials.fetch('web_username')], ['password', @credentials.fetch('web_password')],
        ['redirect', '/merchant-portal'], ['clear', '1']], 'multipart/form-data')
      response = request(URI("#{ORIGIN}/v2/login"), req)
      raise Error, :verification if response.code == '403'
      raise Error, :login if %w[401 419 422].include?(response.code)
      raise Error, :response unless response.code == '200'

      document = JSON.parse(response.body)
      raise Error, :login unless document.is_a?(Hash) && !document['error'] && [true, 1, '1'].include?(document['success'])

      page = get('/merchant-portal')
      @csrf = csrf_from(page.body)
    end

    def csrf_from(html)
      value = Nokogiri::HTML(html).at_css('meta[name="csrf-token"]')&.[]('content')
      raise Error, :response unless value.is_a?(String) && value.bytesize.between?(1, 1024) && !value.match?(/[\x00-\x20\x7f]/)

      value
    end

    def graphql(query, variables)
      req = Net::HTTP::Post.new('/graphql/web', 'Content-Type' => 'application/json')
      req.body = JSON.generate(query: query, variables: variables)
      response = request(URI("#{ORIGIN}/graphql/web"), req)
      raise Error, :login if %w[401 419].include?(response.code)
      raise Error, :response unless response.code == '200' && response['content-type'].to_s.include?('application/json')

      document = JSON.parse(response.body, max_nesting: 30)
      raise Error, :response unless document.is_a?(Hash) && document['errors'].blank? && document['data'].is_a?(Hash)

      document.fetch('data')
    end

    def export(mid, month)
      source = graphql(READ_QUERY, { mid: mid, year: month.year, month: month.month, batches: 'deposits' }).fetch('merchantDailyDeposits')
      raise Error, :response unless source.is_a?(Hash) && source['data'].is_a?(Array) && source['data'].size <= DailyDepositsCsvImport::MAX_ROWS && source['total'].is_a?(Hash)

      result = graphql(EXPORT_QUERY, { mid: mid, year: month.year, month: month.month, batches: 'deposits', exportType: 'csv',
        exportFileName: "Rupert_Deposits_#{month.strftime('%Y_%m')}", exportTitle: 'Daily Deposits' }).fetch('merchantDailyDeposits')
      raise Error, :response unless result.is_a?(Hash)

      @export_url = URI.join(ORIGIN, result.fetch('exportUrl'))
      raise Error, :response unless allowed_export_url?(@export_url)

      response = get(@export_url)
      raise Error, :response unless response['content-type'].to_s.match?(%r{\A(?:text/csv|application/csv|text/plain|application/octet-stream)})

      text = response.body.b.force_encoding(Encoding::UTF_8)
      raise Error, :limit if text.bytesize > DailyDepositsCsvImport::MAX_BYTES
      raise Error, :response unless text.valid_encoding?

      rows = source.fetch('data').map do |row|
        raise Error, :response unless row.is_a?(Hash)

        date = row.fetch('date').to_s
        date = date.match?(%r{\A[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}\z}) ? Date.strptime(date, '%m/%d/%Y') : Date.iso8601(date)
        raise Error, :response unless date.beginning_of_month == month

        { 'date' => date.iso8601, 'amount' => DailyDepositsCsvImport.amount(row.fetch('amount')).to_s('F'),
          'transactions' => DailyDepositsCsvImport.count(row.fetch('transactions')),
          'batch' => DailyDepositsCsvImport.reference(row.fetch('reference_number').to_s),
          'terminal_number' => row['terminal_number'].present? ? DailyDepositsCsvImport.reference(row['terminal_number'].to_s) : nil,
          'type' => DailyDepositsCsvImport.reference(row.fetch('type').to_s) }
      end
      payload = DailyDepositsCsvImport.parse(text: text, period: month.strftime('%Y-%m'))
      raise Error, :response unless payload.fetch('data').sort_by(&:to_json) == rows.sort_by(&:to_json) &&
        BigDecimal(payload.fetch('totals').fetch('amount')) == DailyDepositsCsvImport.amount(source.fetch('total').fetch('amount')) &&
        payload.fetch('totals').fetch('transactions') == DailyDepositsCsvImport.count(source.fetch('total').fetch('transactions'))

      Snapshot.new(merchant: mid, period: month.strftime('%Y-%m'), text: text, rows: rows)
    rescue Client::Error
      raise Error.new(:response), cause: nil
    end

    def get(value)
      url = value.is_a?(URI) ? value : URI.join(ORIGIN, value)
      5.times do
        response = request(url, Net::HTTP::Get.new(url.request_uri))
        if response.is_a?(Net::HTTPRedirection)
          url = URI.join(url, response.fetch('location'))
          raise Error, :login if url.path.start_with?('/v2/login', '/login')
          raise Error, :response unless allowed_origin?(url) && %w[/merchant-portal /merchant-portal/].include?(url.path)

          next
        end
        raise Error, :login if %w[401 419].include?(response.code)
        raise Error, :verification if response.code == '403'
        raise Error, :response unless response.code == '200'

        return response
      end
      raise Error, :response
    end

    def allowed_origin?(url)
      url.scheme == 'https' && url.host == 'nabankco.iriscrm.com' && url.port == 443 && !url.userinfo && !url.fragment
    end

    def allowed_export_url?(url)
      url.scheme == 'https' && url.host == 'cdn.iriscrm.com' && url.port == 443 && !url.userinfo && !url.fragment &&
        url.path.match?(%r{\A/nabankco/tmp/[A-Za-z0-9_.-]+\z}) && !url.path.include?('..')
    end

    def request(url, req)
      vendor = allowed_origin?(url)
      raise Error, :response unless vendor || (req.method == 'GET' && url == @export_url && allowed_export_url?(url))
      if req.method == 'POST'
        raise Error, :response unless vendor && %w[/v2/login /graphql/web].include?(url.path)
      else
        raise Error, :response unless req.method == 'GET' && (%w[/v2/login /merchant-portal /merchant-portal/].include?(url.path) || url == @export_url)
      end
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error, :limit unless remaining.positive?

      req['User-Agent'] = 'Rupert/1.0 NABDailyDepositsReadOnly'
      req['Accept'] = 'application/json,text/html,text/csv'
      req['X-Requested-With'] = 'XMLHttpRequest'
      req['X-CSRF-TOKEN'] = @csrf if vendor && @csrf
      req['Cache-Control'] = 'no-cache, no-store'
      req['Cookie'] = @cookies.values.select { |cookie| url.path.start_with?(cookie[:path]) }.map { |cookie| cookie[:pair] }.join('; ') if vendor
      http = Net::HTTP.new(url.host, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = [5, remaining].min
      http.read_timeout = [15, remaining].min
      http.write_timeout = [10, remaining].min
      http.max_retries = 0
      response = http.request(req) do |result|
        body = +''
        result.read_body do |chunk|
          @bytes += chunk.bytesize
          raise Error, :limit if body.bytesize + chunk.bytesize > MAX_BYTES || @bytes > 32 * 1024 * 1024 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

          body << chunk
        end
        result.body = body
      end
      (vendor ? response.get_fields('set-cookie').to_a : []).each do |line|
        pair, *attributes = line.split(';').map(&:strip)
        path = attributes.find { |a| a.downcase.start_with?('path=') }&.split('=', 2)&.last || '/'
        raise Error, :response unless pair.bytesize <= 4096 && pair.match?(/\A[^\s=;,]+=[^\r\n;]*\z/) && path.start_with?('/')

        @cookies[[path, pair.split('=', 2).first]] = { path: path, pair: pair }
        raise Error, :limit if @cookies.size > 50
      end
      response
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      raise Error.new(:network), cause: nil
    end
  end
end
