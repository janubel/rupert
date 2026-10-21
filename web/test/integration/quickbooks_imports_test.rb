# frozen_string_literal: true

require 'test_helper'

class QuickbooksImportsIntegrationTest < ActionDispatch::IntegrationTest
  FIXTURES = Rails.root.join('test/fixtures/files/quickbooks')

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def upload(name = 'journal_basic.csv', kind: 'journal', **extra)
    file = Rack::Test::UploadedFile.new(FIXTURES.join(name), 'text/csv')
    post finance_quickbooks_imports_path, params: { kind: kind, file: file }.merge(extra)
  end

  def map_everything
    ImportEntityMapping.accounts.each do |mapping|
      code = { 'accounts receivable (a/r)' => '1200', 'sales' => '4000', 'checking' => '1100', 'office supplies' => '5700', 'accounts payable (a/p)' => '2000' }.fetch(mapping.source_key)
      mapping.update!(decision: 'map', target_id: Finance::Account.find_by!(code: code).id)
    end
  end

  test 'upload shows the preview and changes no books' do
    upload
    batch = ImportBatch.last
    assert_redirected_to finance_quickbooks_import_path(batch)
    follow_redirect!
    assert_includes response.body, 'Staged: read, not posted'
    assert_includes response.body, 'Match to Rupert'
    assert_includes response.body, 'Accounts Receivable (A/R)'
    assert_equal 0, Finance::JournalEntry.count
  end

  test 'a bad file shows the reason and retains nothing' do
    file = Rack::Test::UploadedFile.new(StringIO.new("Date,Transaction Type,Account,Amount\n01/01/2024,Check,Checking,5\n"), 'text/csv', original_filename: 'x.csv')
    post finance_quickbooks_imports_path, params: { kind: 'journal', file: file }
    assert_response :unprocessable_entity
    assert_includes response.body, 'single Amount column'
    assert_equal 0, ImportSourceDocument.count
  end

  test 'mapping, approving and reversing work end to end and are logged' do
    upload
    batch = ImportBatch.last
    post approve_finance_quickbooks_import_path(batch), params: { post_through: '2024-12-31' }
    assert_match(/still need a decision/, flash[:alert])
    assert_equal 0, Finance::JournalEntry.count

    changes = ImportEntityMapping.accounts.to_h { |m| [m.id.to_s, { decision: 'create', proposed_code: "9#{m.id}", proposed_type: 'asset' }] }
    patch mappings_finance_quickbooks_import_path(batch), params: { mappings: changes }
    assert_equal 5, ImportEntityMapping.accounts.where(decision: 'create').count
    assert_equal 0, Finance::Account.where('code LIKE ?', '9%').count, 'creating is deferred to approval'

    post approve_finance_quickbooks_import_path(batch), params: { post_through: '2024-12-31' }
    assert_match(/Posted 3 transactions/, flash[:notice])
    assert_equal 3, Finance::JournalEntry.where(kind: 'imported').count
    entry = Finance::JournalEntry.where(kind: 'imported').first
    get finance_journal_entry_path(entry)
    assert_includes response.body, "QuickBooks import batch ##{batch.id}"

    post reverse_finance_quickbooks_import_path(batch), params: { reason: '' }
    assert_equal 3, Finance::JournalEntry.posted.count
    post reverse_finance_quickbooks_import_path(batch), params: { reason: 'Test reversal' }
    assert_equal 0, Finance::JournalEntry.posted.where(kind: 'imported').count
    assert_equal %w[import_batch_approved import_batch_reversed import_batch_staged], ActivityLog.where(action: %w[import_batch_staged import_batch_approved import_batch_reversed]).pluck(:action).sort
  end

  test 'a reader can look but cannot upload, map, approve or reverse' do
    upload
    batch = ImportBatch.last
    reader = User.create!(tenant: @tenant, role: 'reader', email: 'reader@example.com', password: 'password123')
    reader.update_permission_overrides!(%w[dashboard.read finance.read])
    delete logout_path
    post login_path, params: { email: 'reader@example.com', password: 'password123' }
    get finance_quickbooks_imports_path
    assert_response :success
    assert_not_includes response.body, 'Read file'
    get finance_quickbooks_import_path(batch)
    assert_response :success
    assert_not_includes response.body, 'Approve and post'

    assert_no_difference -> { ImportBatch.count } do
      upload('chart_of_accounts.csv', kind: 'chart_of_accounts')
    end
    assert_match(/permission/, flash[:alert])
    post approve_finance_quickbooks_import_path(batch), params: { post_through: '2024-12-31' }
    assert_match(/permission/, flash[:alert])
    patch mappings_finance_quickbooks_import_path(batch), params: { mappings: {} }
    assert_match(/permission/, flash[:alert])
    post reverse_finance_quickbooks_import_path(batch), params: { reason: 'x' }
    assert_match(/permission/, flash[:alert])
  end

  test 'another workspace cannot open a batch' do
    upload
    batch = ImportBatch.last
    other = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'other', shopify_shop_domain: 'other.myshopify.com', status: 'active')
    User.create!(tenant: other, role: 'admin', email: 'other@example.com', password: 'password123')
    delete logout_path
    post login_path, params: { email: 'other@example.com', password: 'password123' }
    get finance_quickbooks_import_path(batch)
    assert_response :not_found
  end

  test 'rejected rows download neutralises spreadsheet formulas' do
    csv = "Trans #,Date,Account,Debit,Credit\n1,01/02/2024,\"=HYPERLINK(\"\"http://x\"\")\",10.00,\n1,01/02/2024,Bank,,abc\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), 'text/csv', original_filename: 'y.csv')
    post finance_quickbooks_imports_path, params: { kind: 'journal', file: file }
    assert_response :redirect, response.body[/role="alert".*?<\/p>/m]
    get rejected_finance_quickbooks_import_path(ImportBatch.last)
    assert_response :success
    assert_includes response.body, "'=HYPERLINK"
    assert_not_includes response.body, ",=HYPERLINK"
  end

  test 'a locked period holds its transactions and the page says why' do
    upload
    batch = ImportBatch.last
    map_everything
    PeriodLock.record!(action: 'lock', kind: 'monthly', date: Date.new(2024, 1, 1), user: users(:regular_user))
    post approve_finance_quickbooks_import_path(batch), params: { post_through: '2024-12-31' }
    assert_match(/2 in a locked period/, flash[:notice])
    follow_redirect!
    assert_includes response.body, 'Staged, not posted'
    assert_includes response.body, 'is locked'
  end
end
