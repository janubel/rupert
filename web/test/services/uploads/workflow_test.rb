# frozen_string_literal: true

require 'test_helper'

class UploadsWorkflowTest < ActiveSupport::TestCase
  include UploadFixtures

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    Current.user = @admin
  end

  teardown do
    Uploads::Registry.reset_extra!
    Current.reset
  end

  def intake(content, name)
    Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: @admin).upload
  end

  def set_params(upload, hash)
    upload.update!(params_json: upload.params.merge(hash).to_json)
  end

  test 'a bank statement dry run changes nothing, then approval imports exactly what it showed' do
    upload = intake(BANK_CSV, 'oct.csv')
    error = assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.dry_run!(upload, actor: @admin) }
    assert_match(/Account name/, error.message)

    set_params(upload, 'account_label' => 'Operating checking')
    assert_no_difference -> { BankStatementLine.count + ReconciliationDocument.count + Finance::Expense.count } do
      Uploads::Workflow.dry_run!(upload, actor: @admin)
    end
    upload.reload
    assert upload.dry_run_current?
    assert_equal 3, upload.summary.dig('dry_run', 'counts', 'New lines')
    assert_equal 'recognized', upload.status

    Uploads::Workflow.import!(upload, actor: @admin)
    upload.reload
    assert_equal 'imported', upload.status
    assert_equal 3, BankStatementLine.count
    assert_equal 1, ReconciliationDocument.where(kind: 'bank_statement').count
    assert_equal @admin.id, upload.imported_by_id
    assert_match(%r{\A/bank_statements/\d+\z}, upload.result_path)
    assert_equal 0, Finance::Expense.count, 'importing lines never creates an expense'
  end

  test 'an import only runs for the file and settings a dry run covered' do
    upload = intake(BANK_CSV, 'oct.csv')
    set_params(upload, 'account_label' => 'Operating checking')
    assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.import!(upload, actor: @admin) }
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    set_params(upload, 'account_label' => 'Another account')
    assert_not upload.reload.dry_run_current?
    error = assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.import!(upload, actor: @admin) }
    assert_match(/dry run/, error.message)
    assert_equal 0, BankStatementLine.count
  end

  test 'a dry run that fails records why and leaves nothing approvable' do
    upload = intake("Date,Description,Amount\nnot-a-date,X,1\n2026-10-15,Y,2\n", 'bad.csv')
    set_params(upload, 'account_label' => 'Operating')
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    upload.reload
    assert_equal 'needs_review', upload.status
    assert_match(/Could not read the date/, upload.reason)
    assert_not upload.dry_run_current?
    assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.import!(upload, actor: @admin) }
  end

  test 'a dry run is rolled back even if an importer writes during it' do
    sneaky = Class.new(Uploads::Importers::Base) do
      importer 'sneaky', label: 'Sneaky', source: 'Test', permission: 'uploads.write', formats: %w[csv]
      def detect(_doc) = detection('sneaky', 'Sneaky', 0.99, 'always')

      def dry_run(_doc, _params, _upload)
        ActivityLog.create!(tenant_id: Current.tenant_id, actor_name: 'x', action: 'sneaky_write')
        outcome('wrote something')
      end

      def import!(_doc, _params, _upload, actor:) = outcome('ok')
    end
    Uploads::Registry.register(sneaky)
    upload = intake(UNKNOWN_CSV, 'x.csv')
    assert_equal 'sneaky', upload.importer_key
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    assert_equal 0, ActivityLog.where(action: 'sneaky_write').count
    assert upload.reload.dry_run_current?
  end

  test 'approval needs the permission of the destination, not just the inbox' do
    upload = intake(BANK_CSV, 'oct.csv')
    set_params(upload, 'account_label' => 'Operating')
    @admin.stubs(:can?).returns(true)
    @admin.stubs(:can?).with('finance.write').returns(false)
    error = assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.dry_run!(upload, actor: @admin) }
    assert_match(/permission/, error.message)
    @admin.stubs(:can?).with('uploads.write').returns(false)
    assert_not Uploads::Workflow.allowed?(Uploads::Importers::BankStatement, @admin)
  end

  test 'NAB / IRIS daily deposits and Authorize.net exports dry-run, then save snapshots' do
    iris = intake(IRIS_CSV, 'dd.csv')
    assert_equal '2026-10', iris.params['period']
    set_params(iris, 'merchant' => '123456789')
    assert_no_difference(-> { IrisReport.count }) { Uploads::Workflow.dry_run!(iris, actor: @admin) }
    assert_equal 2, iris.reload.summary.dig('dry_run', 'counts', 'Deposit rows')
    assert_difference -> { IrisReport.count }, 1 do
      Uploads::Workflow.import!(iris, actor: @admin)
    end

    auth = intake(authnet_csv, 'auth.csv')
    set_params(auth, 'gateway_id' => '987654', 'kind' => 'settled', 'exported_at' => '2026-10-16T09:00:00-04:00')
    assert_no_difference(-> { AuthorizeNetPortalExport.count }) { Uploads::Workflow.dry_run!(auth, actor: @admin) }
    assert auth.reload.dry_run_current?, auth.reason.to_s
    assert_difference -> { AuthorizeNetPortalExport.count }, 1 do
      Uploads::Workflow.import!(auth, actor: @admin)
    end
  end

  test 'SwipeSimple sales dry-run reports orders without creating them' do
    upload = intake(SWIPE_SALES_CSV, 'sales.csv')
    assert_no_difference(-> { Core::Order.count }) { Uploads::Workflow.dry_run!(upload, actor: @admin) }
    assert_equal 2, upload.reload.summary.dig('dry_run', 'counts', 'Orders')
    assert_difference -> { Core::Order.count }, 2 do
      Uploads::Workflow.import!(upload, actor: @admin)
    end
  end

  test 'a person can override the type, and the choice survives re-recognition' do
    upload = intake(UNKNOWN_CSV, 'mystery.csv')
    assert_equal 'needs_review', upload.status
    Uploads::Workflow.choose!(upload, importer_key: 'bank_statement', params: { 'account_label' => 'Savings', 'ignored' => 'x' }, actor: @admin)
    upload.reload
    assert_equal 'recognized', upload.status
    assert upload.operator_chosen
    assert_equal({ 'account_label' => 'Savings' }, upload.params.slice('account_label', 'ignored'))
    Uploads::Workflow.recognize!(upload, actor: @admin)
    assert_equal 'bank_statement', upload.reload.importer_key
    assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.choose!(upload, importer_key: 'nope', actor: @admin) }
    assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.choose!(intake('%PDF-1.4 x', 'a.pdf'), importer_key: 'bank_statement', actor: @admin) }
  end

  test 'discard keeps the original and can be reopened; imported files cannot be discarded' do
    upload = intake(UNKNOWN_CSV, 'mystery.csv')
    Uploads::Workflow.discard!(upload, actor: @admin)
    assert_equal 'rejected', upload.reload.status
    assert upload.discarded?
    assert_equal UNKNOWN_CSV.b, upload.original_bytes
    Uploads::Workflow.reopen!(upload, actor: @admin)
    assert_equal 'needs_review', upload.reload.status
    assert_not upload.discarded?

    sales = intake(SWIPE_SALES_CSV, 'sales.csv')
    Uploads::Workflow.dry_run!(sales, actor: @admin)
    Uploads::Workflow.import!(sales, actor: @admin)
    assert_raises(Uploads::Workflow::Error) { Uploads::Workflow.discard!(sales.reload, actor: @admin) }
  end

  test 'the original cannot be changed through the model' do
    upload = intake(BANK_CSV, 'oct.csv')
    assert_raises(ActiveRecord::ActiveRecordError) { upload.update!(content_base64: Base64.strict_encode64('tampered')) }
    assert_raises(ActiveRecord::ActiveRecordError) { upload.update!(sha256: 'a' * 64) }
    assert_equal BANK_CSV.b, upload.reload.original_bytes
    Upload.where(id: upload.id).update_all(content_base64: Base64.strict_encode64('tampered'))
    assert_raises(RuntimeError) { upload.reload.original_bytes }
    assert_throws(:abort) { upload.destroy! rescue throw(:abort) }
  end
end
