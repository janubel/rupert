# frozen_string_literal: true

require 'test_helper'

class ReceiptWorkflowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @employee = User.create!(tenant: @tenant, email: 'receipt-worker@example.com', password: 'password123', role: 'employee')
    @other = User.create!(tenant: @tenant, email: 'receipt-other@example.com', password: 'password123', role: 'employee')
    @manager = User.create!(tenant: @tenant, email: 'receipt-reviewer@example.com', password: 'password123', role: 'manager')
    @admin = users(:regular_user)
    @receipt = ReceiptWorkflow.new(user: @employee).create(details, upload)
  end
  teardown { Current.reset }

  def details
    { payee: 'Private merchant', incurred_on: Date.current.iso8601, amount: '12.34', category: 'supplies', notes: 'Team supplies' }
  end

  def upload(bytes = '%PDF-1.4 synthetic receipt')
    Rack::Test::UploadedFile.new(StringIO.new(bytes), 'application/pdf', original_filename: 'private-original.pdf')
  end

  def sign_in(user)
    post login_path, params: { email: user.email, password: user == @admin ? 'password' : 'password123' }
    Current.tenant = @tenant
  end

  def submit_receipt
    ReceiptWorkflow.new(user: @employee).change(@receipt, :submit, version: @receipt.lock_version)
  end

  test 'employee upload forces private draft ownership and authenticated downloads' do
    sign_in(@employee)
    get new_receipt_path
    assert_response :success
    assert_select 'input[type=file][required]'
    assert_select 'nav[aria-label="My workspace"] a[href=?]', receipts_path
    assert_difference ['PurchaseReceipt.count', 'PurchaseReceiptEvent.count'], 1 do
      post receipts_path, params: { purchase_receipt: details.merge(file: upload('%PDF-1.4 another file'), submitted_by_id: @admin.id, tenant_id: 'elsewhere', status: 'approved') }
    end
    receipt = PurchaseReceipt.last
    assert_equal @employee.id, receipt.submitted_by_id
    assert_equal @tenant.id, receipt.tenant_id
    assert_equal 'draft', receipt.status
    assert_equal 1234, receipt.amount_cents
    assert_redirected_to receipt_path(receipt)
    get receipt_path(receipt)
    assert_response :success
    assert_equal 'private, no-store', response.headers['Cache-Control']
    assert_select 'button', text: 'Submit for approval'
    get download_receipt_path(receipt)
    assert_response :success
    assert_equal '%PDF-1.4 another file', response.body
    assert_includes response.headers['Content-Disposition'], 'attachment'
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    raw = PurchaseReceipt.connection.select_value("SELECT content_base64 FROM purchase_receipts WHERE id = #{receipt.id.to_i}")
    refute_includes raw, Base64.strict_encode64(response.body)
  end

  test 'independent manager approves once without creating a payment or expense' do
    submit_receipt
    sign_in(@manager)
    get receipts_path
    assert_response :success
    assert_select 'a[href=?]', receipt_path(@receipt)
    get receipt_path(@receipt)
    assert_select 'input[value="Approve receipt"]'
    assert_no_difference ['Finance::Expense.count', 'Core::Payment.count'] do
      assert_difference 'PurchaseReceiptEvent.count', 1 do
        post approve_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1', review_note: 'Matches the purchase.' }
      end
      assert_equal 'approved', @receipt.reload.status
      assert_no_difference 'PurchaseReceiptEvent.count' do
        post approve_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1' }
      end
    end
    assert_equal @manager.id, @receipt.events.last.actor_id
    assert_equal 'Matches the purchase.', @receipt.events.last.note
    assert_equal 1234, JSON.parse(@receipt.events.last.snapshot_json)['amount_cents']
  end

  test 'correction and resubmission retain original and append only review history' do
    submit_receipt
    sign_in(@manager)
    assert_no_difference 'PurchaseReceiptEvent.count' do
      post reject_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1' }
    end
    post reject_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1', review_note: 'Fix the amount.' }
    assert_equal 'rejected', @receipt.reload.status
    sign_in(@employee)
    get receipt_path(@receipt)
    assert_includes response.body, 'Fix the amount.'
    post reopen_receipt_path(@receipt), params: { lock_version: @receipt.lock_version }
    patch receipt_path(@receipt), params: { purchase_receipt: details.merge(amount: '15.20', lock_version: @receipt.reload.lock_version, status: 'approved') }
    assert_equal 1520, @receipt.reload.amount_cents
    assert_equal 'draft', @receipt.status
    assert_equal '%PDF-1.4 synthetic receipt', @receipt.original_bytes
    post submit_receipt_path(@receipt), params: { lock_version: @receipt.lock_version }
    assert_equal 'submitted', @receipt.reload.status
    assert_equal %w[uploaded submit reject reopen update submit], @receipt.events.order(:id).pluck(:action)
    assert_not @receipt.events.last.update(note: 'tampered')
    assert_not @receipt.events.first.destroy
  end

  test 'other employees cannot list download or mutate another persons receipt' do
    sign_in(@other)
    get receipts_path(status: 'all', submitted_by_id: @employee.id)
    assert_response :success
    refute_includes response.body, 'Private merchant'
    [receipt_path(@receipt), edit_receipt_path(@receipt), download_receipt_path(@receipt)].each do |path|
      get path
      assert_response :not_found
    end
    post submit_receipt_path(@receipt), params: { lock_version: @receipt.lock_version }
    assert_response :not_found
    patch receipt_path(@receipt), params: { purchase_receipt: details.merge(lock_version: @receipt.lock_version) }
    assert_response :not_found
  end

  test 'workspace isolation applies even to administrators and downloads' do
    stranger = Tenant.create!(name: 'Other workspace', subdomain: 'other-receipts', status: 'active')
    Current.tenant = stranger
    foreign_user = User.create!(tenant: stranger, email: 'foreign-review@example.com', password: 'password123', role: 'admin')
    foreign_receipt = ReceiptWorkflow.new(user: foreign_user).create(details, upload('%PDF-1.4 foreign file'))
    sign_in(@admin)
    [receipt_path(foreign_receipt), download_receipt_path(foreign_receipt)].each do |path|
      get path
      assert_response :not_found
    end
    post approve_receipt_path(foreign_receipt), params: { lock_version: foreign_receipt.lock_version, confirmed: '1' }
    assert_response :not_found
  end

  test 'even an administrator cannot approve their own receipt' do
    receipt = ReceiptWorkflow.new(user: @admin).create(details, upload('%PDF-1.4 admin receipt'))
    ReceiptWorkflow.new(user: @admin).change(receipt, :submit, version: receipt.lock_version)
    sign_in(@admin)
    post approve_receipt_path(receipt), params: { lock_version: receipt.lock_version, confirmed: '1' }
    assert_equal 'submitted', receipt.reload.status
  end

  test 'forged employee permission overrides cannot grant receipt review' do
    submit_receipt
    @employee.user_permissions.create!(tenant_id: @tenant.id, permission: 'receipts.review', enabled: true)
    sign_in(@employee)
    assert_not @employee.reload.can_review_receipts?
    assert_no_difference 'PurchaseReceiptEvent.count' do
      post approve_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1' }
      post reject_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1', review_note: 'forged' }
    end
    assert_equal 'submitted', @receipt.reload.status
  end

  test 'confirmation stale version and submitted edit checks preserve the review snapshot' do
    submit_receipt
    sign_in(@manager)
    assert_no_difference 'PurchaseReceiptEvent.count' do
      post approve_receipt_path(@receipt), params: { lock_version: @receipt.lock_version }
      post approve_receipt_path(@receipt), params: { lock_version: 0, confirmed: '1' }
      post approve_receipt_path(@receipt), params: { confirmed: '1' }
    end
    assert_equal 'submitted', @receipt.reload.status
    sign_in(@employee)
    patch receipt_path(@receipt), params: { purchase_receipt: details.merge(amount: '90.00', lock_version: @receipt.lock_version) }
    assert_equal 1234, @receipt.reload.amount_cents
  end

  test 'duplicate absent oversized and non receipt files cannot create approval items' do
    sign_in(@employee)
    assert_no_difference ['PurchaseReceipt.count', 'PurchaseReceiptEvent.count'] do
      post receipts_path, params: { purchase_receipt: details.merge(file: upload) }
      assert_response :unprocessable_entity
      assert_includes response.body, 'already uploaded'
      [upload('<html>not a receipt</html>'), upload(''), upload('%PDF-' + 'x' * PurchaseReceipt::MAX_BYTES)].each do |file|
        post receipts_path, params: { purchase_receipt: details.merge(file: file) }
        assert_response :unprocessable_entity
      end
      post receipts_path, params: { purchase_receipt: details }
      assert_response :unprocessable_entity
    end
  end

  test 'invalid amounts dates and review notes roll back state and history' do
    sign_in(@employee)
    ['0', '-1', '1.001', 'abc'].each do |amount|
      assert_no_difference 'PurchaseReceiptEvent.count' do
        patch receipt_path(@receipt), params: { purchase_receipt: details.merge(amount: amount, lock_version: @receipt.lock_version) }
      end
      assert_equal 1234, @receipt.reload.amount_cents
    end
    patch receipt_path(@receipt), params: { purchase_receipt: details.merge(incurred_on: Date.tomorrow.iso8601, lock_version: @receipt.lock_version) }
    assert_equal Date.current, @receipt.reload.incurred_on
    submit_receipt
    sign_in(@manager)
    post approve_receipt_path(@receipt), params: { lock_version: @receipt.lock_version, confirmed: '1', review_note: 'a' * 4001 }
    assert_equal 'submitted', @receipt.reload.status
    assert_equal %w[uploaded submit], @receipt.events.order(:id).pluck(:action)
  end

  test 'ordinary roles see only their own receipts and preview cannot upload' do
    %w[reader shift_leader].each do |role|
      @other.update!(role: role)
      sign_in(@other)
      get receipts_path
      assert_response :success
      refute_includes response.body, 'Private merchant'
      get receipt_path(@receipt)
      assert_response :not_found
      assert_not @other.reload.can_review_receipts?
    end
    sign_in(@employee)
    assert_no_difference 'PurchaseReceipt.count' do
      post receipts_path(preview: 1), params: { purchase_receipt: details.merge(file: upload('%PDF-1.4 forbidden preview')) }
      assert_response :forbidden
      @employee.update!(active: false)
      post receipts_path, params: { purchase_receipt: details.merge(file: upload('%PDF-1.4 deactivated')) }
      assert_redirected_to login_path
    end
  end
end
