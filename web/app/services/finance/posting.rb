# frozen_string_literal: true

module Finance
  # Turns existing money records into balanced journal entries (roadmap F39).
  # Every method is idempotent: it checks for an existing *posted* entry for the
  # source record and returns it instead of double-posting. Account selection is
  # by chart-of-accounts code so the mapping survives tenant account re-seeding.
  #
  # Posting rules (cash vs accrual kept deliberately simple for v1):
  #   expense        DR <expense account>      CR <cash/card by method>
  #   vendor payment DR accounts payable       CR <cash/card by method>
  #   sale           DR <receipt account>      CR sales revenue (+ sales tax)
  #   refund         DR refunds (+ sales tax)  CR <receipt account>
  #
  # Sales are recognised when the payment is taken. Card receipts wait in "Card
  # settlements receivable" (1150) until the processor's deposit clears them;
  # that settlement step (deposit net of fees) is not posted automatically yet.
  class Posting
    # Raised when an entry cannot be posted (for example a required account is
    # missing). Callers post inside the same transaction as the record, so the
    # record is rolled back instead of being saved without its ledger entry.
    class Error < StandardError; end
    # Credit (money-out destination / money-in source) account by tender method.
    CASH_BY_METHOD = {
      'cash' => '1000',          # Cash
      'check' => '1100',         # Checking account
      'bank_transfer' => '1100',
      'ach' => '1100',
      'card' => '2200'           # Credit cards payable (settlement clears it)
    }.freeze

    # Debit (sale) / credit (refund) account by tender. Card receipts are not
    # cash: they sit in the settlements account until the processor deposits.
    # Gift card, check-less "other" and store credit keep the historical Cash
    # treatment; there is no liability account for them yet.
    RECEIPT_BY_METHOD = {
      'card' => '1150',
      'check' => '1100'
    }.freeze
    CARD_CLEARING_CODE = '1150'
    REFUNDS_CODE = '4200'
    # Tenders with no honest ledger treatment yet (they create or consume a
    # liability, not cash); refunds in these are flagged for a manual entry.
    MANUAL_REFUND_METHODS = %w[store_credit gift_card].freeze

    # Default expense account by Finance::Expense category.
    EXPENSE_BY_CATEGORY = {
      'cost_of_goods' => '5000',
      'shipping' => '5100',
      'rent' => '5200',
      'utilities' => '5300',
      'labor' => '5400',
      'marketing' => '5500',
      'advertising' => '5510',
      'store' => '5750',
      'software' => '5600',
      'supplies' => '5700',
      'insurance' => '5800',
      'taxes' => '5900',
      'other' => '6100'
    }.freeze

    REVENUE_CODE = '4000'
    SALES_TAX_CODE = '2100'
    PAYABLE_CODE = '2000'
    FALLBACK_CASH_CODE = '1000'
    FALLBACK_EXPENSE_CODE = '6100'

    class << self
      def expense(expense, created_by: nil)
        posted = JournalEntry.for_source('Finance::Expense', expense.id).posted.first
        return posted if posted

        mapped = Finance::ExpenseCategory.find_key(expense.category)&.ledger_account
        mapped = nil unless mapped&.active?
        account = expense.account || mapped || account(EXPENSE_BY_CATEGORY.fetch(expense.category, FALLBACK_EXPENSE_CODE))
        cash = account(CASH_BY_METHOD.fetch(expense.method, FALLBACK_CASH_CODE))
        entry = JournalEntry.post!(
          kind: 'expense',
          posted_on: expense.incurred_on,
          memo: "Expense · #{expense.category_label}#{expense.payee.present? ? " · #{expense.payee}" : ''}",
          source_type: 'Finance::Expense', source_id: expense.id, created_by: created_by,
          lines: [
            { account_id: account.id, debit_cents: expense.amount_cents, memo: account.name },
            { account_id: cash.id, credit_cents: expense.amount_cents, memo: cash.name }
          ]
        )
        relink_bank_lines(entry, expense_id: expense.id)
        entry
      end

      def vendor_payment(vendor_payment, created_by: nil)
        posted = JournalEntry.for_source('Finance::VendorPayment', vendor_payment.id).posted.first
        return posted if posted

        payable = account(PAYABLE_CODE)
        cash = account(CASH_BY_METHOD.fetch(vendor_payment.method, '1100'))
        entry = JournalEntry.post!(
          kind: 'vendor_payment',
          posted_on: vendor_payment.paid_on,
          memo: "Vendor payment · #{vendor_payment.vendor&.name}",
          source_type: 'Finance::VendorPayment', source_id: vendor_payment.id, created_by: created_by,
          lines: [
            { account_id: payable.id, debit_cents: vendor_payment.amount_cents, memo: payable.name },
            { account_id: cash.id, credit_cents: vendor_payment.amount_cents, memo: cash.name }
          ]
        )
        relink_bank_lines(entry, vendor_payment_id: vendor_payment.id)
        entry
      end

      def sale(payment, created_by: nil)
        posted = JournalEntry.for_source('Core::Payment', payment.id).posted.first
        return posted if posted

        receipt = account(RECEIPT_BY_METHOD.fetch(payment.method.to_s, FALLBACK_CASH_CODE))
        revenue = account(REVENUE_CODE)
        amount = payment.amount_cents.to_i
        tax = sales_tax_portion(payment)
        net = amount - tax
        lines = [
          { account_id: receipt.id, debit_cents: amount, memo: receipt.name },
          { account_id: revenue.id, credit_cents: net, memo: revenue.name }
        ]
        if tax.positive?
          lines << { account_id: account(SALES_TAX_CODE).id, credit_cents: tax, memo: 'Sales tax' }
        end
        JournalEntry.post!(
          kind: 'sale',
          posted_on: (payment.paid_at || Time.current).to_date,
          memo: "Sale · #{payment.order&.order_number}".strip,
          source_type: 'Core::Payment', source_id: payment.id, created_by: created_by,
          lines: lines
        )
      end

      # Money back to the customer: the reverse of a sale for the refunded
      # amount, tax portion included. Idempotent per refund.
      def refund(refund, created_by: nil)
        posted = JournalEntry.for_source('Core::Refund', refund.id).posted.first
        return posted if posted

        if MANUAL_REFUND_METHODS.include?(refund.method.to_s)
          raise Error, "A #{refund.method.to_s.tr('_', ' ')} refund needs a manual journal entry; it was not posted automatically."
        end

        receipt = account(RECEIPT_BY_METHOD.fetch(refund.method.to_s, FALLBACK_CASH_CODE))
        refunds = account(REFUNDS_CODE)
        amount = refund.amount_cents.to_i
        tax = refund_tax_portion(refund)
        lines = [
          { account_id: refunds.id, debit_cents: amount - tax, memo: refunds.name },
          { account_id: receipt.id, credit_cents: amount, memo: receipt.name }
        ]
        lines.insert(1, { account_id: account(SALES_TAX_CODE).id, debit_cents: tax, memo: 'Sales tax refunded' }) if tax.positive?
        JournalEntry.post!(
          kind: 'refund',
          posted_on: (refund.refunded_at || Time.current).to_date,
          memo: "Refund · #{refund.order&.order_number}".strip,
          source_type: 'Core::Refund', source_id: refund.id, created_by: created_by,
          lines: lines
        )
      end

      # Keep a payment's ledger entry true to the payment (the live hook). A
      # completed payment is posted; a changed one is voided and posted again
      # (as expenses are); one that is no longer completed loses its entry.
      def sync_sale(payment, created_by: nil)
        unless payment.status == 'completed'
          void_source('Core::Payment', payment.id)
          return nil
        end
        existing = JournalEntry.for_source('Core::Payment', payment.id).posted.first
        return existing if existing && sale_entry_current?(existing, payment)

        existing&.void!
        sale(payment, created_by: created_by)
      end

      def sync_refund(refund, created_by: nil)
        if refund.discarded?
          void_source('Core::Refund', refund.id)
          return nil
        end

        existing = JournalEntry.for_source('Core::Refund', refund.id).posted.first
        return existing if existing && existing.journal_lines.sum { |l| l.credit_cents.to_i } == refund.amount_cents.to_i

        existing&.void!
        refund(refund, created_by: created_by)
      end

      # Completed payments and live refunds with no posted entry, for the
      # reports notice and the backfill task. Current tenant only.
      def unposted_sales
        Core::Payment.completed.where.not(id: posted_source_ids('Core::Payment'))
      end

      def unposted_refunds
        Core::Refund.where.not(id: posted_source_ids('Core::Refund'))
      end

      # The standard account with this code, seeding the chart if it is missing.
      def ledger_account(code) = account(code)

      # Void the posted entry for a source record (used when an expense changes
      # or is removed). Returns the voided entry, or nil when none was posted.
      def void_source(source_type, source_id)
        entry = JournalEntry.for_source(source_type, source_id).posted.lock.first
        entry&.void!
        entry
      end

      # Re-post every money record that has no entry yet. Safe to re-run.
      def backfill!(created_by: nil)
        counts = { expenses: 0, vendor_payments: 0, sales: 0, refunds: 0 }
        Finance::Expense.find_each do |expense|
          expense(expense, created_by: created_by)
          counts[:expenses] += 1
        end
        Finance::VendorPayment.find_each do |vendor_payment|
          vendor_payment(vendor_payment, created_by: created_by)
          counts[:vendor_payments] += 1
        end
        Core::Payment.completed.find_each do |payment|
          sale(payment, created_by: created_by)
          counts[:sales] += 1
        end
        Core::Refund.find_each do |refund|
          refund(refund, created_by: created_by)
          counts[:refunds] += 1
        end
        counts
      end

      private

      def posted_source_ids(source_type)
        JournalEntry.posted.where(source_type: source_type).select(Arel.sql('CAST(source_id AS INTEGER)'))
      end

      def sale_entry_current?(entry, payment)
        lines = entry.journal_lines
        entry.posted_on == (payment.paid_at || Time.current).to_date &&
          lines.sum { |l| l.debit_cents.to_i } == payment.amount_cents.to_i &&
          lines.any? { |l| l.account_id == account(RECEIPT_BY_METHOD.fetch(payment.method.to_s, FALLBACK_CASH_CODE)).id && l.debit_cents.to_i.positive? }
      end

      # Re-posting a source (after an edit voided its entry) leaves a bank
      # statement line pointing at the voided entry. Move the link to the new
      # entry only when it moves the same amount through the same account, so a
      # changed amount is never silently reconciled.
      def relink_bank_lines(entry, **source)
        BankStatementLine.where(source).where.not(journal_entry_id: [nil, entry.id]).find_each do |line|
          previous = JournalEntry.find_by(id: line.journal_entry_id)
          next unless previous&.status == 'void'

          accounts = signed_by_account(previous).select { |_, cents| cents == line.amount_cents }.keys
          replacement = signed_by_account(entry).select { |_, cents| cents == line.amount_cents }.keys
          line.update!(journal_entry_id: entry.id) if (accounts & replacement).any?
        end
      end

      def signed_by_account(entry)
        entry.journal_lines.group_by(&:account_id).transform_values { |legs| legs.sum { |leg| leg.debit_cents - leg.credit_cents } }
      end

      # A tenant created before the chart of accounts existed (or in a test) may
      # have none; seed the standard chart (idempotent) instead of failing the
      # money record the user is saving. Only missing standard accounts are
      # added; the workspace's existing accounts are never replaced. A code
      # still missing after that is reported plainly so the record rolls back.
      def account(code)
        existing = Finance::Account.find_by(code: code)
        return existing if existing

        Finance::ChartOfAccounts.seed!
        Finance::Account.find_by(code: code) ||
          raise(Error, "Account #{code} is missing from the chart of accounts. Restore or re-create it, then try again. Nothing was saved.")
      end

      # Split a payment's tax out proportionally from its order (orders carry
      # gross + tax; payments do not). Rounds to whole cents; guards divide-by-
      # zero and tax-free orders.
      def sales_tax_portion(payment)
        order = payment.order
        return 0 unless order
        gross = order.gross_cents.to_i
        tax = order.tax_cents.to_i
        return 0 if gross <= 0 || tax <= 0

        # Gross excludes tips; payment receipts include them. Allocate against
        # the complete amount payable, so tips cannot inflate collected tax.
        total = gross + order.tip_cents.to_i
        previous = order.payments.completed.where('id < ?', payment.id).sum(:amount_cents)
        before = [(previous * tax) / total, tax].min
        after = [((previous + payment.amount_cents.to_i) * tax) / total, tax].min
        after - before
      end

      # A refund gives back tax in proportion to the amount refunded, like a
      # payment collected it; earlier refunds on the order use up their share.
      def refund_tax_portion(refund)
        order = refund.order
        return 0 unless order
        gross = order.gross_cents.to_i
        tax = order.tax_cents.to_i
        return 0 if gross <= 0 || tax <= 0

        total = gross + order.tip_cents.to_i
        previous = order.refunds.where('id < ?', refund.id).sum(:amount_cents)
        before = [(previous * tax) / total, tax].min
        after = [((previous + refund.amount_cents.to_i) * tax) / total, tax].min
        after - before
      end
    end
  end
end
