# frozen_string_literal: true

require 'test_helper'

# Sales and refunds reach the ledger as they happen (Core::Payment / Core::Refund
# hooks), card receipts wait in 1150, and the catch-up tasks are dry runs.
class FinanceSalesPostingTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @order = Core::Order.create!(source: 'rupert_pos', source_order_id: 'sales-posting', order_number: 'SP-1', channel: 'pos',
      currency: 'USD', gross_cents: 10_000, tax_cents: 1000, tip_cents: 0, occurred_at: Time.current)
  end

  teardown { Current.reset }

  def pay(method: 'cash', amount: 5500, **extra)
    @order.payments.create!({ method: method, amount_cents: amount, status: 'completed', paid_at: Time.current }.merge(extra))
  end

  def entry_for(record) = Finance::JournalEntry.for_source(record.class.name, record.id).posted.first

  def line_for(entry, code) = entry.journal_lines.find_by!(account_id: Finance::Account.find_by!(code: code).id)

  # A payment saved while the live hook is off, like one that predates it.
  def legacy_payment(**attrs)
    Finance::Posting.stub(:sync_sale, nil) { pay(**attrs) }
  end

  test 'a cash payment is posted on creation: cash in, revenue and tax out' do
    payment = pay(amount: 5500)
    entry = entry_for(payment)
    assert_equal 5500, line_for(entry, '1000').debit_cents
    assert_equal 4950, line_for(entry, '4000').credit_cents
    assert_equal 550, line_for(entry, '2100').credit_cents
  end

  test 'a card payment waits in card settlements receivable, not cash' do
    entry = entry_for(pay(method: 'card'))
    assert_equal 5500, line_for(entry, '1150').debit_cents
    assert_nil entry.journal_lines.find_by(account_id: Finance::Account.find_by!(code: '1000').id)
  end

  test 'posting twice leaves one entry' do
    payment = pay
    Finance::Posting.sync_sale(payment)
    Finance::Posting.sync_sale(payment)
    assert_equal 1, Finance::JournalEntry.for_source('Core::Payment', payment.id).posted.count
  end

  test 'a payment an import later changes is voided and posted again' do
    payment = pay(amount: 5500)
    original = entry_for(payment)
    payment.update!(amount_cents: 6000)
    assert original.reload.void?
    assert_equal 6000, line_for(entry_for(payment), '1000').debit_cents
    assert_equal 1, Finance::JournalEntry.for_source('Core::Payment', payment.id).posted.count
  end

  test 'a payment that stops being completed loses its entry; deleting it does too' do
    cancelled = pay
    cancelled.update!(status: 'failed')
    assert_nil entry_for(cancelled)
    deleted = pay(amount: 4500)
    deleted.destroy!
    assert_empty Finance::JournalEntry.for_source('Core::Payment', deleted.id).posted
  end

  test 'a ledger failure never blocks the payment and is reported as unposted' do
    Rails.error.expects(:report).with(is_a(Finance::Posting::Error), has_entries(handled: true))
    payment = Finance::Posting.stub(:sync_sale, ->(*, **) { raise Finance::Posting::Error, 'ledger refused' }) { pay }
    assert payment.persisted?
    assert_includes Finance::Posting.unposted_sales.pluck(:id), payment.id
  end

  test 'a payment dated inside a locked period is saved and left unposted' do
    PeriodLock.stubs(:lock_covering).returns(Object.new)
    PeriodLock.stubs(:locked_message).returns('Locked')
    payment = pay
    assert payment.persisted?
    assert_nil entry_for(payment)
  end

  test 'a refund reverses the sale for the amount refunded, tax included' do
    refund = @order.refunds.create!(amount_cents: 2200, method: 'card', refunded_at: Time.current)
    entry = entry_for(refund)
    assert_equal 'refund', entry.kind
    assert_equal 1980, line_for(entry, '4200').debit_cents
    assert_equal 220, line_for(entry, '2100').debit_cents
    assert_equal 2200, line_for(entry, '1150').credit_cents
  end

  test 'a discarded refund loses its entry, and store credit is left for a manual entry' do
    refund = @order.refunds.create!(amount_cents: 1000, method: 'cash', refunded_at: Time.current)
    refund.discard!
    assert_nil entry_for(refund)
    credit = nil
    Rails.error.stubs(:report)
    credit = @order.refunds.create!(amount_cents: 1000, method: 'store_credit', refunded_at: Time.current)
    assert_nil entry_for(credit)
    assert_includes Finance::Posting.unposted_refunds.pluck(:id), credit.id
  end

  test 'catch-up is a dry run that lists unposted records by month, then posts them' do
    payment = legacy_payment
    refund = Finance::Posting.stub(:sync_refund, nil) { @order.refunds.create!(amount_cents: 1000, method: 'cash', refunded_at: Time.current) }
    backfill = Finance::SalesBackfill.new
    rows = backfill.plan
    assert_equal %w[refund sale], rows.map(&:kind).sort
    assert_nil entry_for(payment)
    assert_nil entry_for(refund)

    result = backfill.apply!
    assert_equal 2, result.posted
    assert_empty result.refused
    assert_empty backfill.plan
  end

  test 'catch-up reports what a locked period refuses and keeps going' do
    legacy_payment
    PeriodLock.stubs(:lock_covering).returns(Object.new)
    PeriodLock.stubs(:locked_message).returns('Locked period')
    result = Finance::SalesBackfill.new.apply!
    assert_equal 0, result.posted
    assert_equal 1, result.refused.size
  end

  test 'card receipts posted to cash are reclassified once a month, and a re-run adds nothing' do
    payment = legacy_payment(method: 'card', amount: 5500)
    cash = Finance::Account.find_by!(code: '1000')
    revenue = Finance::Account.find_by!(code: '4000')
    Finance::JournalEntry.post!(kind: 'sale', posted_on: payment.paid_at.to_date, source_type: 'Core::Payment', source_id: payment.id,
      lines: [{ account_id: cash.id, debit_cents: 5500 }, { account_id: revenue.id, credit_cents: 5500 }])
    reclass = Finance::CardReclass.new
    row = reclass.plan.sole
    assert_equal [payment.paid_at.strftime('%Y-%m'), 5500], [row.month, row.amount_cents]

    posted, refused = reclass.apply!
    assert_equal 1, posted.size
    assert_empty refused
    entry = Finance::JournalEntry.where(source_type: Finance::CardReclass::SOURCE_TYPE).sole
    assert_equal 5500, line_for(entry, '1150').debit_cents
    assert_equal 5500, line_for(entry, '1000').credit_cents
    assert_empty reclass.plan
  end

  test 'the reclass dry run on a tenant with no chart writes nothing' do
    Finance::Account.delete_all
    assert_empty Finance::CardReclass.new.plan
    assert_equal 0, Finance::Account.count
  end

  test 'the standard chart now includes the card settlements account' do
    assert_equal 'asset', Finance::Account.find_by!(code: '1150').account_type
  end

  test 'the reports notice says how many payments are still missing from the ledger' do
    assert_equal Finance::ReportsController::COVERAGE_NOTICE, Finance::ReportsController.coverage_notice
    legacy_payment
    assert_match(/1 completed payment or refund is not in the ledger yet\./, Finance::ReportsController.coverage_notice)
  end
end
