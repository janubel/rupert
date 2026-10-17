# frozen_string_literal: true

module Finance
  # Money out grouped by who it went to. A payee is a vendor when the record
  # names one, otherwise the free-text payee on an expense. Expenses and vendor
  # payments stay in separate columns because a payment can settle a bill that
  # is also recorded as an expense; they are never added into one total.
  # Read-only, bounded by the date range, and all amounts are integer cents.
  class PayeeActivity
    Entry = Struct.new(:kind, :id, :on, :cents, :category, :method, :reference, :key, :label, keyword_init: true)
    Summary = Struct.new(:key, :label, :vendor_id, :expense_cents, :expense_count, :payment_cents, :payment_count, :last_on, keyword_init: true)

    BANK_SCAN_LIMIT = 5_000
    NONE = 'Unlabelled'

    attr_reader :from, :to

    def initialize(from:, to:)
      @from = from
      @to = to
    end

    def entries
      @entries ||= (expense_entries + payment_entries).sort_by { |e| [e.on, e.id] }.reverse
    end

    def summaries
      @summaries ||= entries.group_by(&:key).map do |key, rows|
        expenses = rows.select { |r| r.kind == :expense }
        payments = rows.select { |r| r.kind == :payment }
        Summary.new(key: key, label: rows.first.label, vendor_id: key.start_with?('v:') ? key.delete_prefix('v:').to_i : nil,
          expense_cents: expenses.sum(&:cents), expense_count: expenses.size,
          payment_cents: payments.sum(&:cents), payment_count: payments.size, last_on: rows.map(&:on).max)
      end.sort_by { |s| [-(s.expense_cents + s.payment_cents), s.label.downcase] }
    end

    def entries_for(key) = entries.select { |e| e.key == key }
    def summary_for(key) = summaries.find { |s| s.key == key }

    # Statement lines whose description mentions the payee. Descriptions are
    # encrypted at rest, so the match is made in memory over the range only.
    def bank_lines_for(label)
      return [] if label.blank? || label == NONE

      needle = label.downcase
      BankStatementLine.where(posted_on: from..to).order(posted_on: :desc, id: :desc).limit(BANK_SCAN_LIMIT)
        .select { |line| line.description.to_s.downcase.include?(needle) }
    end

    private

    def expense_entries
      rows = Finance::Expense.where(incurred_on: from..to).pluck(:id, :incurred_on, :amount_cents, :category, :method, :payee, :vendor_id, :reference)
      rows.map do |id, on, cents, category, method, payee, vendor_id, reference|
        key, label = identity(vendor_id, payee)
        Entry.new(kind: :expense, id: id, on: on, cents: cents, category: category, method: method, reference: reference, key: key, label: label)
      end
    end

    def payment_entries
      rows = Finance::VendorPayment.where(paid_on: from..to).pluck(:id, :paid_on, :amount_cents, :method, :vendor_id)
      rows.map do |id, on, cents, method, vendor_id|
        key, label = identity(vendor_id, nil)
        Entry.new(kind: :payment, id: id, on: on, cents: cents, category: nil, method: method, reference: nil, key: key, label: label)
      end
    end

    def identity(vendor_id, payee)
      return ["v:#{vendor_id}", vendor_names.fetch(vendor_id, "Vendor ##{vendor_id}")] if vendor_id

      text = payee.to_s.strip
      text.empty? ? ['p:', NONE] : ["p:#{text.downcase}", text]
    end

    def vendor_names
      @vendor_names ||= Purchasing::Vendor.pluck(:id, :name).to_h
    end
  end
end
