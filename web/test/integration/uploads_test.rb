# frozen_string_literal: true

require 'test_helper'

class UploadsIntegrationTest < ActionDispatch::IntegrationTest
  include UploadFixtures

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @reader = User.create!(tenant: @tenant, email: 'reader-uploads@example.com', role: 'reader', password: 'password', name: 'Reader')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def send_files(*files)
    post uploads_path, params: { files: files }
  end

  test 'sign-in and the permission are both required' do
    delete logout_path
    get uploads_path
    assert_redirected_to login_path
    post login_path, params: { email: 'reader-uploads@example.com', password: 'password' }
    get uploads_path
    assert_redirected_to root_path
    post uploads_path, params: { files: [upload_file(BANK_CSV, 'a.csv')] }
    assert_equal 0, Upload.count
    assert_not_includes ModuleRegistry.nav_for(@reader).map(&:key), 'uploads'
    assert_includes ModuleRegistry.nav_for(@admin).map(&:key), 'uploads'
  end

  test 'a view-only person can look but not send, decide or discard' do
    upload = Uploads::Intake.call(StringIO.new(BANK_CSV), filename: 'a.csv', origin: 'web', actor: @admin).upload
    UserPermission.create!(tenant_id: @tenant.id, user: @reader, permission: 'uploads.read', enabled: true)
    delete logout_path
    post login_path, params: { email: 'reader-uploads@example.com', password: 'password' }
    get upload_path(upload)
    assert_response :success
    assert_select 'form[action=?]', dry_run_upload_path(upload), count: 0
    assert_select 'form[action=?]', discard_upload_path(upload), count: 0
    assert_select 'input[type=file]', count: 0
    post discard_upload_path(upload)
    post uploads_path, params: { files: [upload_file(UNKNOWN_CSV, 'b.csv')] }
    assert_equal 'recognized', upload.reload.status
    assert_equal 1, Upload.count
  end

  test 'the page offers a drop zone and a real file picker and lists every upload' do
    get uploads_path
    assert_response :success
    assert_select 'input[type=file][multiple][name="files[]"]'
    assert_select '[data-controller=dropzone]'
    assert_select 'label[for=upload-files]'
    send_files(upload_file(BANK_CSV, 'oct.csv'), upload_file(UNKNOWN_CSV, 'mystery.csv'), upload_file('MZ', 'run.exe', 'application/octet-stream'))
    follow_redirect!
    assert_select 'table td a', text: 'oct.csv'
    assert_select 'table td a', text: 'run.exe'
    assert_match(/2 files received/, flash[:notice])
    assert_match(/Unsupported file type/, flash[:alert])
    assert_equal %w[needs_review recognized rejected], Upload.pluck(:status).sort
    get uploads_path(status: 'needs_review')
    assert_select 'table td a', text: 'mystery.csv'
    assert_select 'table td a', text: 'oct.csv', count: 0
  end

  test 'the detail page shows the type, reason and a preview that is escaped and never calculated' do
    send_files(upload_file(HOSTILE_CSV, 'hostile.csv'))
    upload = Upload.last
    follow_redirect!
    assert_response :success
    assert_no_match(/<script>alert\(1\)<\/script>/, response.body)
    assert_includes response.body, '&lt;script&gt;alert(1)&lt;/script&gt;'
    assert_select '.upload-formula-mark', minimum: 3
    assert_select '.upload-heading-row'
    assert_includes response.body, upload.sha256
    assert_no_match(/href="[^"]*(evil\.test)/, response.body)
    assert_equal 'private, no-store', response.headers['Cache-Control']
  end

  test 'a workbook preview shows cached values as text' do
    send_files(upload_file(build_xlsx([['Name', 'Note'], ['=1+1', 'ok']]), 'book.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'))
    follow_redirect!
    assert_response :success
    assert_select '.upload-preview td', text: /=1\+1/
    assert_select '.upload-formula-mark'
  end

  test 'full flow: confirm type, dry run, approve, and nothing changes before approval' do
    send_files(upload_file(BANK_CSV, 'oct.csv'))
    upload = Upload.last
    follow_redirect!
    assert_select 'form[action=?]', dry_run_upload_path(upload)
    assert_select 'input[name="fields[account_label]"]'
    assert_select 'form[action=?]', approve_upload_path(upload), count: 0

    assert_no_difference -> { BankStatementLine.count } do
      post dry_run_upload_path(upload), params: { fields: { account_label: 'Operating checking' } }
    end
    follow_redirect!
    assert_match(/Nothing was changed/, flash[:notice].to_s + response.body)
    assert_select 'form[action=?]', approve_upload_path(upload)
    assert_includes response.body, 'Dry run result (current)'

    post approve_upload_path(upload)
    assert_redirected_to upload_path(upload)
    assert_equal 3, BankStatementLine.count
    follow_redirect!
    assert_select 'a', text: 'See the imported records'
    assert_equal 'imported', upload.reload.status
    assert ActivityLog.where(action: 'upload_imported').exists?
  end

  test 'approval without a matching dry run is refused with a plain message' do
    send_files(upload_file(BANK_CSV, 'oct.csv'))
    upload = Upload.last
    post approve_upload_path(upload)
    assert_redirected_to upload_path(upload)
    assert_match(/dry run/i, flash[:alert])
    assert_equal 0, BankStatementLine.count
  end

  test 'confirming another type, re-running recognition, discarding and reopening' do
    send_files(upload_file(UNKNOWN_CSV, 'mystery.csv'))
    upload = Upload.last
    patch choose_upload_path(upload), params: { importer_choice: 'bank_statement|', fields: { account_label: 'Savings' } }
    assert_redirected_to upload_path(upload)
    assert upload.reload.operator_chosen
    post recognize_all_uploads_path
    assert_redirected_to uploads_path
    post discard_upload_path(upload)
    assert_equal 'rejected', upload.reload.status
    post reopen_upload_path(upload)
    assert_equal 'needs_review', upload.reload.status, 'reopening starts over from what Rupert recognizes'
  end

  test 'the original downloads exactly, only as an attachment' do
    send_files(upload_file(HOSTILE_CSV, 'hostile.csv'))
    upload = Upload.last
    get original_upload_path(upload)
    assert_response :success
    assert_equal HOSTILE_CSV.b, response.body.b
    assert_match(/attachment/, response.headers['Content-Disposition'])
    assert_equal 'application/octet-stream', response.media_type
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    assert ActivityLog.where(action: 'data_exported').exists?
  end

  test 'a duplicate points back at the first copy and a rejected file shows its reason' do
    send_files(upload_file(BANK_CSV, 'oct.csv'))
    send_files(upload_file(BANK_CSV, 'copy.csv'))
    duplicate = Upload.where(status: 'duplicate').last
    get upload_path(duplicate)
    assert_select 'a', text: /Upload #\d+ \(oct.csv\)/
    send_files(upload_file('nope', 'x.exe', 'application/octet-stream'))
    get upload_path(Upload.last)
    assert_match(/Why it was not kept or used/, response.body)
  end

  test 'too many files or too large a request is refused before anything is stored' do
    files = Array.new(11) { |i| upload_file("a,b\n#{i},1\n", "f#{i}.csv") }
    send_files(*files)
    assert_match(/up to 10 files/i, flash[:alert])
    assert_equal 0, Upload.count
    post uploads_path
    assert_match(/Choose at least one file/, flash[:alert])
  end

  test 'another workspace cannot see or open an upload' do
    send_files(upload_file(BANK_CSV, 'oct.csv'))
    upload = Upload.last
    other = Tenant.create!(name: 'Other uploads web', subdomain: 'other-uploads-web')
    outsider = User.create!(tenant: other, email: 'outsider-uploads@example.com', role: 'admin', password: 'password')
    delete logout_path
    host! "#{other.subdomain}.example.com"
    post login_path, params: { email: outsider.email, password: 'password' }
    get upload_path(upload)
    assert_response :not_found
    get uploads_path
    assert_select 'table td a', text: 'oct.csv', count: 0
    get original_upload_path(upload)
    assert_response :not_found
  end

  test 'Ask Rupert can point a person at the page' do
    found = AskRupert::Guide.new(@admin).where_is('where do I upload a file')
    assert_includes found[:pages].map { |page| page[:path] }, '/uploads'
    assert_empty AskRupert::Guide.new(@reader).where_is('upload a file')[:pages].select { |page| page[:path] == '/uploads' }
  end
end
