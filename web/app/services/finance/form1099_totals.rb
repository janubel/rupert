# frozen_string_literal: true

module Finance
  # What each 1099 payee was paid in a calendar year (#472): expenses and vendor payments to that vendor or payee name,
  # and paid payslips for a contractor on staff. Card payments are left out, since the card processor reports them on a
  # 1099-K. "Other" payment methods are counted but flagged, as they may be payment apps (also 1099-K). Amounts are cents.
  class Form1099Totals
    # The reporting threshold by tax year. The 2025 tax law raised 1099-NEC/MISC from $600 to $2,000 for payments made
    # after 2025 (indexed for inflation later). Royalties (MISC box 2) stay at $10. Confirm each year with a tax preparer.
    THRESHOLDS = { 2025 => 600_00 }.freeze
    LATER_THRESHOLD = 2_000_00
    ROYALTY_THRESHOLD = 10_00

    Row = Struct.new(:payee, :paid_cents, :card_cents, :other_method_cents, :count, keyword_init: true) do
      def threshold_cents(year) = Form1099Totals.threshold_cents(year, payee)

      # 'needed', 'under', 'exempt' or 'none'.
      def status(year)
        return 'none' if payee.form_type == 'none'
        return 'exempt' if payee.likely_exempt?

        paid_cents >= threshold_cents(year) ? 'needed' : 'under'
      end
    end

    attr_reader :year, :rows

    def self.threshold_cents(year, payee)
      return ROYALTY_THRESHOLD if payee.form_type == 'misc' && payee.misc_box == '2'

      THRESHOLDS.fetch(year) { year < 2025 ? 600_00 : LATER_THRESHOLD }
    end

    def initialize(year:)
      @year = year.to_i
      @range = Date.new(@year, 1, 1)..Date.new(@year, 12, 31)
      @rows = Finance::TaxPayee.order(:legal_name).map { |payee| row_for(payee) }
    end

    def needed = rows.select { |row| row.status(year) == 'needed' }

    private

    def row_for(payee)
      amounts = payments_for(payee.payee_key) # [[cents, method], ...]
      card, rest = amounts.partition { |_cents, method| method == 'card' }
      Row.new(payee: payee, paid_cents: rest.sum(&:first), card_cents: card.sum(&:first),
        other_method_cents: rest.select { |_cents, method| method == 'other' }.sum(&:first), count: rest.size)
    end

    def payments_for(key)
      case key
      when /\Av:(\d+)\z/
        id = Regexp.last_match(1).to_i
        Finance::Expense.where(vendor_id: id, incurred_on: @range).pluck(:amount_cents, :method) +
          Finance::VendorPayment.where(vendor_id: id, paid_on: @range).pluck(:amount_cents, :method)
      when /\Ae:(\d+)\z/
        People::Payslip.joins(:pay_run).where(employee_id: Regexp.last_match(1).to_i, pay_runs: { status: 'paid', paid_on: @range })
          .pluck(:gross_cents).map { |cents| [cents, 'payroll'] }
      else
        name = key.delete_prefix('p:')
        Finance::Expense.where(vendor_id: nil, incurred_on: @range).where('LOWER(TRIM(payee)) = ?', name).pluck(:amount_cents, :method)
      end
    end
  end
end
