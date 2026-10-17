# frozen_string_literal: true

# Bank cash movement and recorded expenses are deliberately separate. A payout
# is not a second sale; transfers are not expenses; this is not a profit report.
class BookkeepingOverview
  Error = Class.new(ArgumentError)
  attr_reader :month, :account, :accounts

  def initialize(month: nil, account: nil, today: Date.current)
    @accounts = BankStatementLine.distinct.order(:account_label).pluck(:account_label)
    @account = account.present? ? account.to_s : @accounts.first
    raise Error, 'Choose a bank account from the list.' if @account && !@accounts.include?(@account)

    latest = account_lines.maximum(:posted_on)
    @month = month.present? ? parse_month(month) : (latest || today).beginning_of_month
  end

  def from = month
  def to = month.end_of_month
  def previous_month = (month - 1.month).strftime('%Y-%m')
  def next_month = (month + 1.month).strftime('%Y-%m')
  def account_lines = BankStatementLine.where(account_label: account)
  def lines = account_lines.where(posted_on: from..to)
  def line_count = lines.count
  def pending_count = lines.pending.count
  def flagged_count = lines.flagged.pending.count
  def decided_count = line_count - pending_count
  def progress = line_count.zero? ? 0 : decided_count * 100 / line_count
  def credits_cents = lines.where('amount_cents > 0').sum(:amount_cents)
  def debits_cents = -lines.where('amount_cents < 0').sum(:amount_cents)
  def net_cents = credits_cents - debits_cents
  def expenses = Finance::Expense.where(incurred_on: from..to)
  def expense_cents = expenses.sum(:amount_cents)
  def expense_categories = expenses.group(:category).sum(:amount_cents).sort_by { |_, amount| -amount }
  def vendor_payment_cents = Finance::VendorPayment.where(paid_on: from..to).sum(:amount_cents)
  def questions = lines.pending.order(review_flag: :desc, posted_on: :asc, id: :asc).limit(8)
  def recent_lines = lines.order(posted_on: :desc, id: :desc).limit(8)
  def statements = ReconciliationDocument.where(id: lines.distinct.select(:document_id)).order(period_to: :desc, id: :desc)
  def open_follow_ups = ReconciliationFollowUp.active.where('period_from <= ? AND period_to >= ?', to, from)

  # Only explicitly supplied currency is displayed. Legacy CSV uploads do not
  # establish currency, and statements from other accounts are never combined.
  def currency
    documents = statements.to_a
    return nil if documents.empty?

    originals = ReconciliationDocument.where(source: 'bank', kind: 'bank_statement')
      .where('period_from <= ? AND period_to >= ?', to, from).to_a
    values = documents.map do |doc|
      own = doc.metadata['currency'].presence
      linked = originals.select { |pdf| pdf.metadata['derived_transaction_document_id'] == doc.id }
      currencies = ([own] + linked.map { |pdf| pdf.metadata['currency'].presence }).compact.uniq
      currencies.one? ? currencies.first : nil
    end
    values.none?(&:nil?) && values.uniq.one? ? values.first : nil
  end

  def statement_balance
    ids = statements.pluck(:id)
    return nil if ids.empty?

    docs = ReconciliationDocument.where(source: 'bank', kind: 'bank_statement')
      .where(period_to: from..to).order(period_to: :desc, id: :desc)
    docs.each do |doc|
      meta = doc.metadata
      next unless ids.include?(doc.id) || ids.include?(meta['derived_transaction_document_id'])
      next unless meta['closing_balance_cents'].is_a?(Integer) && meta['currency'].present?

      return { cents: meta['closing_balance_cents'], currency: meta['currency'], date: doc.period_to, document: doc }
    end
    nil
  end

  private

  def parse_month(value)
    raise Error, 'Choose a month in YYYY-MM format.' unless value.to_s.match?(/\A20\d{2}-\d{2}\z/)

    Date.iso8601("#{value}-01")
  rescue Date::Error
    raise Error, 'Choose a valid calendar month.'
  end
end
