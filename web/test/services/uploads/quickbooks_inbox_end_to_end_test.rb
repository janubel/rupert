# frozen_string_literal: true

require 'test_helper'

# The Uploads inbox with the real QuickbooksCsv / QuickbooksImport behind it:
# receiving, dry-running and approving only ever stages a batch; the books change
# only on the batch's own approval.
class UploadsQuickbooksEndToEndTest < ActiveSupport::TestCase
  include UploadFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.user = @admin
  end

  teardown { Current.reset }

  def intake(content, name) = Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: @admin).upload

  test 'the importer is installed and recognizes the QuickBooks kinds' do
    assert Uploads::Importers::Quickbooks.available?
    assert_equal 'quickbooks', intake(QB_JOURNAL_CSV, 'journal.csv').importer_key
  end

  test 'a journal is staged through the inbox, not posted' do
    upload = intake(QB_JOURNAL_CSV, 'journal.csv')
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    assert_equal 2, upload.reload.summary.dig('dry_run', 'counts', 'Rows read')
    assert_no_difference ['Finance::JournalEntry.count', 'Finance::Account.count', 'ImportBatch.count'] do
      Uploads::Workflow.dry_run!(upload, actor: @admin)
    end
    Uploads::Workflow.import!(upload, actor: @admin)
    batch = ImportBatch.last
    assert_equal ['staged', 'journal', 1], [batch.status, batch.kind, batch.transaction_count]
    assert_equal 0, Finance::JournalEntry.count
    assert_equal 'imported', upload.reload.status
  end

  test 'a trial balance with a blank account header is staged with its as-of date' do
    upload = intake(QB_TRIAL_CSV, 'tb.csv')
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    Uploads::Workflow.import!(upload, actor: @admin)
    batch = ImportBatch.last
    assert_equal ['trial_balance', Date.new(2026, 10, 31), 2], [batch.kind, batch.as_of, batch.row_count]
  end

  test 'the same file sent twice never stages two batches' do
    first = intake(QB_COA_CSV, 'coa.csv')
    Uploads::Workflow.dry_run!(first, actor: @admin)
    Uploads::Workflow.import!(first, actor: @admin)
    assert_equal 1, ImportBatch.count
    assert_equal 'duplicate', intake(QB_COA_CSV, 'coa-again.csv').status
  end
end
