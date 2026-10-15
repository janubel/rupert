# frozen_string_literal: true

require 'test_helper'

# SwipeSimple CSV import: parses the export, feeds the canonical sales stream
# (orders + lines + payments + ledger), and stays idempotent on re-import.
class SwipesimpleImportTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'sync@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id,
      name: 'Sync')
    post login_path, params: { email: 'sync@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  CSV_TEXT = <<~CSV
    Order,Date,Item,SKU,Qty,Unit Price,Total,Payment,Customer,Status,Currency
    1001,2026-07-01T14:30:00-04:00,Honey Sticks,TEA-50,2,14.00,28.00,Card,Alex Morgan,Completed,USD
    1001,2026-07-01T14:30:00-04:00,Peppermint Oil,OIL-3,1,12.50,12.50,Card,Alex Morgan,Completed,USD
    1002,2026-07-02T14:30:00-04:00,CBD Gummies,GUM-1,1,$9.99,$9.99,Cash,Jamie Rivera,Paid,USD
  CSV

  test 'importer handles a line-level export with flexible columns' do
    result = SyncEngine.import_swipesimple_csv!(CSV_TEXT, actor: 'test')

    assert_equal 2, result.orders
    assert_equal 3, result.lines
    assert_equal 0, result.skipped_rows

    order = Core::Order.find_by!(source: 'swipesimple', source_order_id: '1001')
    assert_equal 'paid', order.status
    assert_equal 4050, order.gross_cents # 28.00 + 12.50
    assert_equal 2, order.order_lines.count
    assert_equal 1400, order.order_lines.find_by(sku: 'TEA-50').unit_cents
    assert_equal 2800, order.order_lines.find_by(sku: 'TEA-50').line_cents
    assert_equal 1, order.payments.count
    assert_equal 'card', order.payments.first.method
    assert_equal 4050, order.payments.first.amount_cents

    order2 = Core::Order.find_by!(source: 'swipesimple', source_order_id: '1002')
    assert_equal 999, order2.gross_cents # $9.99
    assert_equal 'cash', order2.payments.first.method

    assert_equal 'SS-1001', order.display_number
    assert LedgerEntry.exists?(source: 'swipesimple', sourceOrderId: '1001')
    assert LedgerEntry.exists?(source: 'swipesimple', sourceOrderId: '1002')
    run = SyncRun.find_by!(source: 'swipesimple', mode: 'csv')
    assert run.success?
  end

  test 're-importing the same file is idempotent' do
    SyncEngine.import_swipesimple_csv!(CSV_TEXT, actor: 'test')
    SyncEngine.import_swipesimple_csv!(CSV_TEXT, actor: 'test')

    assert_equal 2, Core::Order.where(source: 'swipesimple').count
    assert_equal 3, Core::Order.where(source: 'swipesimple').sum(:line_items)
    assert_equal 2, LedgerEntry.where(source: 'swipesimple').count
  end

  test 'rows without a stable order id are rejected without business writes' do
    csv = CSV_TEXT.sub('1001,', ',')
    assert_no_difference ['Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count'] do
      assert_raises(SwipesimpleImporter::Error) { SyncEngine.import_swipesimple_csv!(csv, actor: 'test') }
    end
  end

  test 'controller imports an uploaded CSV and redirects with a summary' do
    file = Tempfile.new(['swipesimple', '.csv'])
    file.write(CSV_TEXT)
    file.rewind

    post preview_swipesimple_syncs_path(format: :json), params: {
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv')
    }
    assert_response :success
    preview_token = response.parsed_body.fetch('preview_token')
    file.rewind

    post(import_swipesimple_syncs_path, params: {
           file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
           preview_token: preview_token,
           shop: 'm11u0i-sb.myshopify.com',
           embedded: '1',
           host: 'test-host'
         })
    follow_redirect!
    assert_response(:success)
    assert_match(/Imported 2 new order\(s\), 3 line\(s\)/, flash[:notice])
    assert_equal(2, Core::Order.where(source: 'swipesimple').count)
  ensure
    file&.close
    file&.unlink
  end

  test 'a reader cannot upload a SwipeSimple import' do
    User.create!(email: 'reader2@example.com', password: 'password123', role: 'reader', tenant_id: @tenant.id,
      name: 'Reader')
    delete logout_path
    post login_path, params: { email: 'reader2@example.com', password: 'password123' }

    post import_swipesimple_syncs_path, params: {
      text: CSV_TEXT,
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1',
      host: 'test-host'
    }
    follow_redirect!
    assert_match(/don't have permission/, flash[:alert])
    assert_equal 0, Core::Order.where(source: 'swipesimple').count
  end

  test 'preview is private and creates no business rows or sync run' do
    assert_no_difference ['Core::Order.unscoped.count', 'Core::Payment.unscoped.count', 'LedgerEntry.unscoped.count', 'SyncRun.unscoped.count', 'Setting.unscoped.count'] do
      post preview_swipesimple_syncs_path(format: :json), params: { text: CSV_TEXT }
    end
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    result = response.parsed_body
    assert_equal 2, result.dig('preview', 'orders')
    assert_equal 5049, result.dig('preview', 'gross_cents')
    assert_equal 'USD', result.dig('preview', 'currency')
    assert result['preview_token'].present?
    assert_not_includes response.body, 'Alex Morgan'
    assert_not_includes response.body, 'TEA-50'
  end

  test 'HTML preview does not echo uploaded data and supports a reviewed reupload' do
    post preview_swipesimple_syncs_path, params: { text: CSV_TEXT }
    assert_response :success
    assert_select 'form[action=?]', import_swipesimple_syncs_path
    assert_select 'input[name=preview_token][value]'
    assert_select 'meta[name=turbo-cache-control][content=no-cache]'
    assert_includes response.body, 'Validated preview'
    assert_not_includes response.body, 'Alex Morgan'
    assert_not_includes response.body, 'TEA-50'
  end

  test 'direct import without a reviewed preview is rejected' do
    assert_no_difference ['Core::Order.unscoped.count', 'SyncRun.unscoped.count'] do
      post import_swipesimple_syncs_path, params: { text: CSV_TEXT }
    end
    assert_redirected_to syncs_path(anchor: 'swipesimple')
    assert_match(/Preview this export/, flash[:alert])
  end

  test 'a reviewed export cannot be changed before import' do
    token = reviewed_token
    assert_no_difference ['Core::Order.unscoped.count', 'Core::Payment.unscoped.count', 'LedgerEntry.unscoped.count'] do
      post import_swipesimple_syncs_path, params: { text: CSV_TEXT.sub('1001,', 'other-order,'), preview_token: token }
    end
    assert_redirected_to syncs_path(anchor: 'swipesimple')
    assert flash[:alert].present?
  end

  test 'expired and tampered preview tokens cannot authorize an import' do
    token = reviewed_token
    travel 16.minutes do
      assert_no_difference ['Core::Order.unscoped.count', 'SyncRun.unscoped.count'] do
        post import_swipesimple_syncs_path, params: { text: CSV_TEXT, preview_token: token }
      end
      assert_match(/Preview this export/, flash[:alert])
    end
    assert_no_difference ['Core::Order.unscoped.count', 'SyncRun.unscoped.count'] do
      post import_swipesimple_syncs_path, params: { text: CSV_TEXT, preview_token: token + 'tampered' }
    end
  end

  test 'a preview is bound to the reviewing user and tenant' do
    token = reviewed_token
    other_tenant = Tenant.create!(name: 'Other store', subdomain: 'other-store')
    other = User.create!(email: 'other-sync@example.com', password: 'password123', role: 'admin', tenant: other_tenant)
    delete logout_path
    post login_path, params: { email: other.email, password: 'password123' }
    assert_no_difference ['Core::Order.unscoped.count', 'SyncRun.unscoped.count'] do
      post import_swipesimple_syncs_path, params: { text: CSV_TEXT, preview_token: token }
    end
    assert_match(/Preview this export/, flash[:alert])
  end

  test 'another administrator in the same tenant cannot reuse a preview' do
    token = reviewed_token
    other = User.create!(email: 'same-store-sync@example.com', password: 'password123', role: 'admin', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: other.email, password: 'password123' }
    assert_no_difference ['Core::Order.unscoped.count', 'SyncRun.unscoped.count'] do
      post import_swipesimple_syncs_path, params: { text: CSV_TEXT, preview_token: token }
    end
    assert_match(/Preview this export/, flash[:alert])
  end

  test 'oversized and malformed exports fail without echoing raw contents' do
    post preview_swipesimple_syncs_path(format: :json), params: { text: 'x' * (SwipesimpleImporter::MAX_BYTES + 1) }
    assert_response :unprocessable_entity
    assert_match(/too large/, response.parsed_body['error'])
    post preview_swipesimple_syncs_path(format: :json), params: { text: "Order,Date\n\"Private Customer" }
    assert_response :unprocessable_entity
    assert_not_includes response.body, 'Private Customer'
  end

  test 'CSV import respects active sync ownership and recovers stale runs' do
    run = SyncRun.create!(mode: 'scheduled', status: 'running', source: 'all', actor: 'scheduler', startedAt: Time.current)
    assert_no_difference ['Core::Order.count', 'SyncRun.count'] do
      assert_raises(SyncEngine::AlreadyRunning) { SyncEngine.import_swipesimple_csv!(CSV_TEXT) }
    end
    assert_equal 'running', run.reload.status
    assert_nil Current.sync_run
    run.update!(startedAt: 46.minutes.ago)
    SyncEngine.import_swipesimple_csv!(CSV_TEXT)
    assert_equal 'failed', run.reload.status
    assert SyncRun.find_by!(mode: 'csv').success?
  end

  test 'cache failure cannot turn committed CSV sales into a failed import' do
    DataCache.stubs(:bump!).raises(StandardError, 'synthetic cache failure')
    summary = SyncEngine.import_swipesimple_csv!(CSV_TEXT)
    assert_equal 2, summary.orders
    assert SyncRun.find_by!(mode: 'csv').success?
    assert_nil Current.sync_run
  end

  private

  def reviewed_token
    post preview_swipesimple_syncs_path(format: :json), params: { text: CSV_TEXT }
    assert_response :success
    response.parsed_body.fetch('preview_token')
  end
end
