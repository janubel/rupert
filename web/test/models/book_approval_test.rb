# frozen_string_literal: true

require 'test_helper'

class BookApprovalTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @period = BooksPeriod.new(kind: 'daily', date: Date.current - 3)
  end

  teardown { Current.reset }

  def approve!(status: 'approved', notes: nil)
    BookApproval.record!(period: @period, status: status, notes: notes, user: @user)
  end

  test 'records who, when and the evidence fingerprint' do
    freeze_time do
      approval = approve!
      assert_equal @user.id, approval.approved_by_id
      assert_equal Time.current.utc.floor(6), approval.approved_at
      assert_equal @period.digest, approval.report_digest
      assert_equal BookApproval::GENESIS, approval.prev_hash
      assert_equal approval.expected_hash, approval.entry_hash
    end
  end

  test 'entries chain to the one before and the chain verifies' do
    first = approve!
    second = approve!(status: 'needs_attention', notes: 'Cash drawer short')
    assert_equal first.entry_hash, second.prev_hash
    assert_equal({ ok: true, count: 2 }, BookApproval.verify_chain)
  end

  test 'rows cannot be updated or deleted through the application' do
    approval = approve!
    assert_not approval.update(status: 'approved_with_exceptions')
    assert_not approval.destroy
    assert BookApproval.exists?(approval.id)
  end

  test 'tampering with a stored row is detected' do
    approve!
    second = approve!(notes: 'ok')
    BookApproval.unscoped.where(id: second.id).update_all(approved_by_name: 'Someone Else')
    result = BookApproval.verify_chain
    assert_not result[:ok]
    assert_equal second.id, result[:broken_id]
  end

  test 'removing an earlier row breaks the chain' do
    first = approve!
    approve!(notes: 'second')
    BookApproval.unscoped.where(id: first.id).delete_all
    assert_not BookApproval.verify_chain[:ok]
  end

  test 'exceptions and attention flags need a note' do
    assert_raises(ActiveRecord::RecordInvalid) { approve!(status: 'approved_with_exceptions') }
    assert_raises(ActiveRecord::RecordInvalid) { approve!(status: 'needs_attention', notes: ' ') }
  end

  test 'notes are encrypted at rest' do
    approval = approve!(status: 'approved_with_exceptions', notes: 'Counted twice')
    raw = ActiveRecord::Base.connection.select_value("SELECT notes FROM book_approvals WHERE id = #{approval.id}")
    assert_not_includes raw, 'Counted twice'
  end
end
