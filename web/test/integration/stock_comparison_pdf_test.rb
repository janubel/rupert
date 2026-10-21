# frozen_string_literal: true

require 'test_helper'

class StockComparisonPdfTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    @at = Time.current.change(usec: 0)
    product = ShopifyProduct.create!(id: 'pdf-product', title: 'Tea', status: 'ACTIVE', catalog_present: true, catalog_read_at: @at)
    @matched = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/pdf-1', product: product, title: '30 count', sku: '77001',
      tracked: true, catalog_present: true, catalog_read_at: @at)
    @online = Location.create!(source: 'shopify', externalId: 'pdf-online', name: 'Online')
    @retail = Location.create!(source: 'ctrax', externalId: 'pdf/1', name: 'Retail')
    ShopifyStockSnapshot.create!(location: @online, shop_domain: 'fixture.myshopify.com', captured_at: @at,
      records_json: [{ 'id' => @matched.id, 'available' => 5, 'on_hand' => 5, 'committed' => 0 }])
    CtraxStockSnapshot.create!(location: @retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: @at,
      records_json: [{ 'id' => 'ct-1', 'sku' => '77001', 'name' => 'Tea 30 count', 'quantity' => '5', 'manage_stock' => true },
        { 'id' => 'ct-2', 'sku' => '88002', 'name' => 'Loose leaf', 'quantity' => '-2', 'manage_stock' => true }])
  end

  teardown { Current.reset }

  test 'downloads the filtered comparison as a read-only PDF and logs the export' do
    params = { shopify_location_id: @online.id, ctrax_location_id: @retail.id }
    counts = -> { [ShopifyStockSnapshot, CtraxStockSnapshot, ShopifyVariant, ShopifyProduct, Location, InventoryLevel].map(&:count) }
    before = counts.call

    assert_difference -> { ActivityLog.where(action: 'data_exported').count }, 1 do
      get stock_comparison_path(params.merge(format: :pdf))
    end
    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_includes response.headers['Content-Disposition'], 'attachment'
    assert response.body.start_with?('%PDF')
    assert_includes pdf_text(response.body), '77001'
    assert_includes pdf_text(response.body), '88002'
    assert_equal before, counts.call

    get stock_comparison_path(params.merge(format: :pdf, filter: 'attention'))
    assert_response :success
    text = pdf_text(response.body)
    assert_includes text, '88002'
    refute_includes text, '77001'
    assert_includes text, 'Needs attention'
  end

  test 'service keeps unknown stock distinct from zero and repeats headers across pages' do
    records = Array.new(150) { |i| { 'id' => "bulk-#{i}", 'name' => "Bulk item #{i}", 'quantity' => (i.zero? ? nil : '1'), 'manage_stock' => true } }
    CtraxStockSnapshot.find_by!(location: @retail).update!(records_json: records)
    comparison = StockComparison.new(shopify_location_id: @online.id, ctrax_location_id: @retail.id, at: @at)
    pdf = StockComparisonPdf.new(comparison, at: @at)
    text = pdf_text(pdf.render)

    assert_operator pdf.document.page_count, :>, 1
    assert_operator text.scan('Identity').size, :>=, pdf.document.page_count
    assert_includes text, 'Unknown'
    assert_includes text, "Page 1 of #{pdf.document.page_count}"
  end

  test 'the stock comparison page links to the PDF with the current selections' do
    get stock_comparison_path(shopify_location_id: @online.id, ctrax_location_id: @retail.id, filter: 'attention', q: 'tea')
    assert_response :success
    link = css_select('a').find { |a| a.text == 'Download store comparison PDF' }
    params = Rack::Utils.parse_query(URI.parse(link['href']).query)
    assert_equal({ 'q' => 'tea', 'filter' => 'attention', 'shopify_location_id' => @online.id.to_s, 'ctrax_location_id' => @retail.id.to_s },
      params.except('format'))
    get link['href']
    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  test 'the PDF reader retains a compressed stream ending in a carriage return byte' do
    stream = (0..255).lazy.map do |padding|
      Zlib::Deflate.deflate("[<3838303032>] TJ\n%#{'a' * padding}")
    end.find { |bytes| bytes.getbyte(-1) == 13 }
    assert stream, 'fixture must exercise the trailing carriage-return byte'
    assert_includes pdf_text("stream\n".b + stream + "\nendstream".b), '88002'
  end

  private

  # Inflate the content streams, then join each text operator's hex fragments
  # (kerning splits words) into readable lines.
  def pdf_text(body)
    # Prawn writes LF before endstream. An optional CR here consumes a real
    # trailing 0x0d byte in some compressed streams and invalidates their checksum.
    content = body.b.scan(/stream\r?\n(.*?)\nendstream/m).flatten.map do |stream|
      Zlib::Inflate.inflate(stream)
    rescue Zlib::Error
      stream
    end.join("\n")
    content.scan(/\[([^\]]*)\]\s*TJ|<(\h*)>\s*Tj/).map do |array, single|
      (single ? [single] : array.scan(/<(\h*)>/).flatten).map { |hex| [hex].pack('H*') }.join
    end.join("\n").force_encoding('Windows-1252').encode('UTF-8')
  end

  test 'the store comparison PDF is one click from Inventory, Reports and the Stock menu' do
    pdf = "a[href^='/stock_comparison'][href*='pdf']"
    get inventory_index_path
    assert_select pdf, 'Store comparison PDF'
    get inventory_reports_path
    assert_select pdf, 'Download store comparison PDF'
    get stock_comparison_path
    assert_select 'a#store-comparison-pdf.btn-primary', 'Download store comparison PDF'
    assert_select "nav[aria-label='Module'] a[aria-current='page']", /Store comparison/
    assert_equal 'stock', ModuleRegistry.area_key_for('stock_comparison')
  end
end
