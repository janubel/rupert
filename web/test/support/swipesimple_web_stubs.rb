# frozen_string_literal: true

require 'caxlsx'

# Synthetic SwipeSimple website responses for tests. No real merchant data.
module SwipesimpleWebStubs
  ITEM_HEADERS = %w[id name sku price tax status track_inventory on_hand_count category].freeze
  DEFAULT_ITEMS = [
    [101, 'Blue Dream Flower 3.5g', 'BD-35', 35, 'PA Tax', 'active', 'true', 12, 'Flower'],
    [102, 'Rolling Papers', nil, 9.9, 'No Tax', 'active', 'false', 40, 'Accessories'],
    [103, 'Old Lighter', 'LT-1', 2, 'PA Tax', 'removed', 'true', 0, 'Accessories']
  ].freeze
  DEFAULT_TAXES = [[1, 'PA Tax', 6.0], [2, 'No Tax', 0.0], [3, 'Local Tax', 2.0]].freeze

  def json_response(document)
    { status: 200, body: document.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  def stub_login
    return_url = '/connect/authorize/callback?state=fixture'
    login_url = "https://login.cardflight.com/login?ReturnUrl=#{URI.encode_www_form_component(return_url)}"
    stub_request(:get, 'https://swipesimple.com/sign_in').to_return(status: 302,
      headers: { 'Location' => login_url, 'Set-Cookie' => 'swipe=own-session; Path=/; Secure' })
    stub_request(:get, login_url).to_return(status: 200, body: '<html>Sign in</html>')
    stub_request(:get, "https://login.cardflight.com/api/v1/login/context?returnUrl=#{URI.encode_www_form_component(return_url)}")
      .to_return(json_response(data: { clientId: 'fixture-client' }))
    stub_request(:post, 'https://login.cardflight.com/api/v1/login').with { |request| !request.headers['Cookie'].to_s.include?('swipe=') }
      .to_return(json_response(data: { status: 'Authenticated' }).merge(headers: { 'Content-Type' => 'application/json', 'Set-Cookie' => 'cardflight=own-login; Path=/; Secure' }))
    stub_request(:get, "https://login.cardflight.com#{return_url}").to_return(status: 302,
      headers: { 'Location' => 'https://swipesimple.com/companies/42/dashboard' })
    stub_request(:get, 'https://swipesimple.com/companies/42/dashboard').to_return(status: 200, body: '<html>Dashboard</html>')
    stub_request(:get, 'https://swipesimple.com/transactions').with { |request| !request.headers['Cookie'].to_s.include?('cardflight=') }
      .to_return(status: 200, body: '<a href="/companies/42/dashboard">Company</a>')
  end

  def empty_report(topic)
    headers = SwipesimpleWeb::ReportCsv::HEADERS.fetch(topic)
    totals = ['Totals', *Array.new(headers.size - 1, '$0.00')]
    totals[1] = '' if topic == 'tax' # the Tax Rate column
    "#{headers.join(',')}\n#{totals.join(',')}\n"
  end

  # Every report request answers with an empty (no sales) report unless a
  # block supplies a body for (topic, start_date, end_date).
  def stub_reports(&body)
    stub_request(:get, %r{\Ahttps://swipesimple\.com/companies/42/reports\.csv}).to_return do |request|
      query = Rack::Utils.parse_nested_query(request.uri.query)
      topic = query.dig('report', 'topic')
      text = body&.call(topic, query['start_date'], query['end_date']) || empty_report(topic)
      { status: 200, body: text, headers: { 'Content-Type' => 'text/csv; charset=utf-8' } }
    end
  end

  def items_xlsx(items: DEFAULT_ITEMS, taxes: DEFAULT_TAXES, shared_strings: true, item_headers: ITEM_HEADERS, sheets: %w[Instructions Items Taxes])
    package = Axlsx::Package.new
    package.use_shared_strings = shared_strings
    sheets.each do |name|
      package.workbook.add_worksheet(name: name) do |sheet|
        case name
        when 'Items' then [item_headers, *items].each { |row| sheet.add_row(row) }
        when 'Taxes' then [%w[id name value], *taxes].each { |row| sheet.add_row(row) }
        else sheet.add_row(['Fictional instructions: status is active or removed.'])
        end
      end
    end
    package.to_stream.read
  end

  def stub_items(bytes = items_xlsx)
    stub_request(:get, 'https://swipesimple.com/items.xlsx').to_return(status: 200, body: bytes, headers: { 'Content-Type' => 'application/xlsx' })
  end
end
