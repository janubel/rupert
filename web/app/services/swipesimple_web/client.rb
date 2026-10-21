# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'csv'
require 'digest'

module SwipesimpleWeb
  # Uses the website's own sign-in and read/export endpoints. This is not a
  # published partner API. Each instance creates a new, memory-only session.
  class Client
    class Error < StandardError
      MESSAGES = {
        invalid: 'Save the SwipeSimple company ID, email and password before pulling.',
        login: 'SwipeSimple sign-in failed. Check the saved email and password; automatic pulls are paused.',
        verification: 'SwipeSimple requires additional sign-in verification. Automatic pulls are paused.',
        network: 'SwipeSimple could not be reached securely. The previous snapshots were retained.',
        response: 'SwipeSimple changed its website response or returned an incomplete export. The previous snapshots were retained.',
        identity: 'SwipeSimple returned a different company or merchant account. The previous snapshots were retained.',
        limit: 'SwipeSimple exceeds the supported export limit. The previous snapshots were retained.',
        changed: 'SwipeSimple setup changed during the pull. Nothing was imported.'
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

    HOSTS = %w[swipesimple.com login.cardflight.com].freeze
    LIMIT = SwipesimpleReportImporter::MAX_BYTES
    REPORT_TOPICS = %w[tax sales].freeze
    CSV_TYPES = %r{\A(?:text/csv|application/csv|application/octet-stream)}
    XLSX_TYPES = %r{\A(?:application/xlsx|application/vnd\.openxmlformats-officedocument\.spreadsheetml\.sheet|application/octet-stream)}
    Snapshot = Struct.new(:kind, :text, :exported_at, :merchant_account, keyword_init: true)
    ReportChunk = Struct.new(:topic, :from, :to, :text, :rows, :sha256, :exported_at, keyword_init: true)
    ItemsSnapshot = Struct.new(:records, :sha256, :exported_at, keyword_init: true)

    def initialize(credentials, company_id:)
      @credentials = credentials
      @company_id = company_id.to_s
      @cookies = {}
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      unless @company_id.match?(/\A[1-9][0-9]{0,19}\z/) && credentials['web_email'].to_s.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/) && credentials['web_password'].present?
        raise Error, :invalid
      end
    end

    def fetch
      guarded do
        sign_in!
        transactions = export('transactions')
        accounts = CSV.parse(transactions.text.delete_prefix("\uFEFF"), headers: true).map { |row| row['Merchant Account'].to_s.strip }.uniq
        raise Error, :identity unless accounts.one? && accounts.first.present?

        transactions.merchant_account = accounts.first
        invoices = export('invoices')
        invoices.merchant_account = accounts.first
        [transactions, invoices]
      end
    end

    # Reporting -> tax or sales CSV for from..to, one request per calendar month.
    # Each month is parsed and checked (headers, dates inside the month, day
    # rows add up to SwipeSimple's Totals) before it is returned.
    def report(topic, from:, to:, pause: 0)
      raise ArgumentError, 'Unknown SwipeSimple report.' unless REPORT_TOPICS.include?(topic)
      raise ArgumentError, 'Choose an ordered date range.' unless from.is_a?(Date) && to.is_a?(Date) && from <= to

      guarded do
        sign_in!
        self.class.months(from, to).each_with_index.map do |(first, last), index|
          sleep(pause) if index.positive? && pause.positive?
          report_month(topic, first, last)
        end
      end
    end

    # Items -> Export workbook, parsed into item-snapshot records.
    def items_workbook
      guarded do
        sign_in!
        refresh_deadline!
        response, url = get('https://swipesimple.com/items.xlsx')
        raise Error, :login unless url.host == 'swipesimple.com' && url.path == '/items.xlsx'
        raise Error, :response unless response['content-type'].to_s.match?(XLSX_TYPES)

        bytes = response.body.to_s.b
        ItemsSnapshot.new(records: ItemsWorkbook.parse(bytes), sha256: Digest::SHA256.hexdigest(bytes), exported_at: Time.current.utc.iso8601(6))
      rescue ItemsWorkbook::Error
        raise Error.new(:response), cause: nil
      end
    end

    def self.months(from, to)
      chunks = []
      first = from
      while first <= to
        last = [first.end_of_month, to].min
        chunks << [first, last]
        first = last + 1
      end
      chunks
    end

    private

    def guarded
      yield
    rescue CSV::MalformedCSVError, JSON::ParserError, KeyError, TypeError, URI::InvalidURIError
      raise Error.new(:response), cause: nil
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError
      raise Error.new(:network), cause: nil
    end

    # One sign-in and company check per client; later reads reuse that session.
    def sign_in!
      return if @signed_in

      login!
      page, url = get('https://swipesimple.com/transactions')
      raise Error, :login unless url.host == 'swipesimple.com' && url.path == '/transactions'

      companies = Nokogiri::HTML(page.body).css('a[href]').filter_map { |a| a['href'][%r{\A(?:https://swipesimple\.com)?/companies/(\d+)/}, 1] }.uniq
      raise Error, :identity unless companies == [@company_id]

      @signed_in = true
    end

    # Each report or workbook read gets its own bounded time budget.
    def refresh_deadline!
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
    end

    def report_month(topic, first, last)
      refresh_deadline!
      url = URI("https://swipesimple.com#{reports_path}")
      # Only these verified ISO parameters; anything else falls back to the
      # last 30 days, which the date check below would reject.
      url.query = URI.encode_www_form([['report[topic]', topic], ['start_date', first.iso8601], ['end_date', last.iso8601]])
      response, final = get(url)
      raise Error, :login unless final.host == 'swipesimple.com' && final.path == reports_path
      raise Error, :response unless response['content-type'].to_s.match?(CSV_TYPES)

      text = response.body.to_s.b.force_encoding(Encoding::UTF_8)
      rows = ReportCsv.parse(text, topic: topic, from: first, to: last)
      ReportChunk.new(topic: topic, from: first, to: last, text: text, rows: rows, sha256: Digest::SHA256.hexdigest(text.b),
        exported_at: Time.current.utc.iso8601(6))
    rescue ReportCsv::Error
      raise Error.new(:response), cause: nil
    end

    def reports_path = "/companies/#{@company_id}/reports.csv"

    def login!
      _response, url = get('https://swipesimple.com/sign_in')
      raise Error, :verification unless url.host == 'login.cardflight.com' && url.path == '/login'

      return_url = URI.decode_www_form(url.query.to_s).to_h.fetch('ReturnUrl')
      raise Error, :response unless return_url.start_with?('/connect/authorize/callback?')

      context_url = URI('https://login.cardflight.com/api/v1/login/context')
      context_url.query = URI.encode_www_form(returnUrl: return_url)
      response, = get(context_url)
      document = JSON.parse(response.body)
      raise Error, :response unless document.is_a?(Hash) && document['data'].is_a?(Hash)

      context = document.fetch('data')
      client_id = context.fetch('clientId')
      raise Error, :response unless client_id.is_a?(String) && client_id.match?(/\A[a-zA-Z0-9_-]{1,200}\z/)

      request = Net::HTTP::Post.new('/api/v1/login')
      request.set_form([['email', @credentials.fetch('web_email')], ['password', @credentials.fetch('web_password')], ['clientId', client_id]], 'multipart/form-data')
      response = send_request(URI('https://login.cardflight.com/api/v1/login'), request)
      raise Error, :login if [400, 401, 403].include?(response.code.to_i)
      raise Error, :response unless response.code == '200'

      document = JSON.parse(response.body)
      raise Error, :response unless document.is_a?(Hash) && document['data'].is_a?(Hash)

      data = document.fetch('data')
      raise Error, :login if data['status'] == 'Failed'
      raise Error, :verification unless data['status'] == 'Authenticated'

      _response, final = get(URI.join('https://login.cardflight.com', return_url))
      raise Error, :login unless final.host == 'swipesimple.com' && !final.path.start_with?('/sign_in')
    end

    def export(kind)
      # No date/search filters: request fresh full native exports each time.
      count_response, count_url = get("https://swipesimple.com/#{kind}.json?iDisplayStart=0&iDisplayLength=1&sEcho=1")
      raise Error, :login unless count_url.host == 'swipesimple.com' && count_url.path == "/#{kind}.json"

      counts = JSON.parse(count_response.body)
      raise Error, :response unless counts.is_a?(Hash)

      total = counts.fetch('iTotalRecords')
      filtered = counts.fetch('iTotalDisplayRecords')
      raise Error, :response unless total.is_a?(Integer) && total >= 0 && total == filtered
      raise Error, :limit if total > SwipesimpleReportImporter::MAX_ROWS

      response, url = get("https://swipesimple.com/#{kind}.csv?time_zone=America%2FNew_York")
      raise Error, :login unless url.host == 'swipesimple.com' && url.path == "/#{kind}.csv"
      raise Error, :response unless response['content-type'].to_s.match?(CSV_TYPES)

      text = response.body.to_s.b.force_encoding(Encoding::UTF_8)
      raise Error, :response unless text.valid_encoding? && CSV.parse(text.delete_prefix("\uFEFF"), headers: true).size == total

      Snapshot.new(kind: kind, text: text, exported_at: Time.current.utc.iso8601(6))
    end

    def get(value)
      url = value.is_a?(URI) ? value : URI(value)
      12.times do
        response = send_request(url, Net::HTTP::Get.new(url.request_uri))
        if response.is_a?(Net::HTTPRedirection)
          destination = URI.join(url.to_s, response.fetch('location'))
          # The verified provider currently emits an http:// URL for this one
          # login-page redirect. Never request HTTP: upgrade this exact GET to TLS.
          if url.host == 'login.cardflight.com' && destination.host == url.host && destination.scheme == 'http' && destination.path == '/login' && destination.port == 80
            destination.scheme = 'https'
            destination.port = 443
          end
          url = destination
          next
        end
        raise Error, :login if [401, 403].include?(response.code.to_i)
        raise Error, :response unless response.code == '200'

        return [response, url]
      end
      raise Error, :response
    end

    def send_request(url, request)
      raise Error, :response unless allowed_url?(url, request.method)
      raise Error, :network if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

      http = Net::HTTP.new(url.host, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.read_timeout = 15
      http.write_timeout = 15
      request['User-Agent'] = 'Rupert/1.0 SwipeSimpleReadOnlyWebSync'
      request['Accept'] = url.path.end_with?('.xlsx') ? 'application/xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'text/html,application/json,text/csv'
      request['Cache-Control'] = 'no-cache, no-store'
      request['Cookie'] = @cookies.values.select { |cookie| cookie[:host] == url.host && url.path.start_with?(cookie[:path]) }.map { |cookie| cookie[:pair] }.join('; ')
      response = http.request(request) do |result|
        body = +''
        result.read_body do |chunk|
          raise Error, :limit if body.bytesize + chunk.bytesize > LIMIT
          raise Error, :network if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

          body << chunk
        end
        result.body = body
      end
      response.get_fields('set-cookie').to_a.each do |line|
        pair, *attributes = line.split(';').map(&:strip)
        name = pair.split('=', 2).first
        path = attributes.find { |a| a.downcase.start_with?('path=') }&.split('=', 2)&.last || '/'
        next unless pair.match?(/\A[^\s=;,]+=[^\r\n;]*\z/) && path.start_with?('/')

        # Host-only isolation is intentionally stricter than domain cookies.
        @cookies[[url.host, path, name]] = { host: url.host, path: path, pair: pair }
      end
      response
    end

    def allowed_url?(url, method)
      return false unless url.scheme == 'https' && HOSTS.include?(url.host) && url.port == 443 && !url.userinfo && !url.fragment
      return url.host == 'login.cardflight.com' && url.path == '/api/v1/login' if method == 'POST'
      return false unless method == 'GET'

      if url.host == 'login.cardflight.com'
        %w[/oauth2/authorize /connect/authorize /connect/authorize/callback /login /api/v1/login/context].include?(url.path)
      else
        %w[/ /sign_in /sign_in_v2 /sign_in_v2_handoff /transactions /transactions.csv /transactions.json /invoices.csv /invoices.json /items.xlsx].include?(url.path) ||
          url.path.match?(%r{\A/companies/[1-9][0-9]*/dashboard\z}) || url.path == reports_path
      end
    end
  end
end
