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
  #   sale           DR <cash by method>       CR sales revenue (+ sales tax)
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
        JournalEntry.post!(
          kind: 'expense',
          posted_on: expense.incurred_on,
          memo: "Expense · #{expense.category_label}#{expense.payee.present? ? " · #{expense.payee}" : ''}",
          source_type: 'Finance::Expense', source_id: expense.id, created_by: created_by,
          lines: [
            { account_id: account.id, debit_cents: expense.amount_cents, memo: account.name },
            { account_id: cash.id, credit_cents: expense.amount_cents, memo: cash.name }
          ]
        )
      end

      def vendor_payment(vendor_payment, created_by: nil)
        posted = JournalEntry.for_source('Finance::VendorPayment', vendor_payment.id).posted.first
        return posted if posted

        payable = account(PAYABLE_CODE)
        cash = account(CASH_BY_METHOD.fetch(vendor_payment.method, '1100'))
        JournalEntry.post!(
          kind: 'vendor_payment',
          posted_on: vendor_payment.paid_on,
          memo: "Vendor payment · #{vendor_payment.vendor&.name}",
          source_type: 'Finance::VendorPayment', source_id: vendor_payment.id, created_by: created_by,
          lines: [
            { account_id: payable.id, debit_cents: vendor_payment.amount_cents, memo: payable.name },
            { account_id: cash.id, credit_cents: vendor_payment.amount_cents, memo: cash.name }
          ]
        )
      end

      def sale(payment, created_by: nil)
        posted = JournalEntry.for_source('Core::Payment', payment.id).posted.first
        return posted if posted

        # All receipts land in Cash; splitting card vs cash settlement is a
        # bank-reconciliation concern (roadmap F40), not a posting concern.
        cash = account(FALLBACK_CASH_CODE)
        revenue = account(REVENUE_CODE)
        amount = payment.amount_cents.to_i
        tax = sales_tax_portion(payment)
        net = amount - tax
        lines = [
          { account_id: cash.id, debit_cents: amount, memo: cash.name },
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

      # Void the posted entry for a source record (used when an expense changes
      # or is removed). Returns the voided entry, or nil when none was posted.
      def void_source(source_type, source_id)
        entry = JournalEntry.for_source(source_type, source_id).posted.lock.first
        entry&.void!
        entry
      end

      # Re-post every money record that has no entry yet. Safe to re-run.
      def backfill!(created_by: nil)
        counts = { expenses: 0, vendor_payments: 0, sales: 0 }
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
        counts
      end

      private

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
    end
  end
end
