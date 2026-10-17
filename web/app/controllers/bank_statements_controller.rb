# frozen_string_literal: true

# Upload a bank statement CSV, then decide line by line what each withdrawal
# is. Nothing becomes an expense or vendor payment until a person chooses it.
class BankStatementsController < AuthenticatedController
  include ApprovedPeriodNotice

  before_action -> { authorize(:module, :finance_read?) }
  before_action -> { authorize(:module, :finance_write?) }, only: %i[create decide]
  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def index
    @statements = BankStatementLine.group(:document_id, :account_label)
      .pluck(:document_id, :account_label, Arel.sql('COUNT(*)'), Arel.sql("SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END)"),
        Arel.sql('MIN(posted_on)'), Arel.sql('MAX(posted_on)'))
      .sort_by { |row| -row.first }
    @documents = ReconciliationDocument.where(id: @statements.map(&:first)).select(:id, :filename, :created_at).index_by(&:id)
    @can_write = Current.user.can?('finance.write')
  end

  def create
    file = params[:file]
    raise BankStatementImport::Error, 'Choose a CSV file no larger than 8 MiB.' unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size.between?(1, ReconciliationEvidence::MAX_BYTES)

    importer = BankStatementImport.new(bytes: file.read, account_label: params[:account_label], withdrawals_positive: params[:withdrawals_positive] == '1')
    result = importer.import!(filename: file.original_filename, actor: Current.user)
    ActivityLogger.log('bank_statement_uploaded', subject: result[:document],
      details: "#{params[:account_label].to_s.strip}: #{result[:created]} new line(s), #{result[:duplicates]} already seen, #{result[:from]}..#{result[:to]}")
    notice = "#{result[:created]} line(s) ready to review"
    notice += "; #{result[:duplicates]} already seen and skipped" if result[:duplicates].positive?
    redirect_to bank_statement_path(result[:document].id), notice: "#{notice}. The original file is retained unchanged."
  rescue BankStatementImport::Error, ReconciliationEvidence::Error => e
    @statements = []
    @documents = {}
    @can_write = true
    @form_error = e.message
    render :index, status: :unprocessable_entity
  end

  def show
    @document = ReconciliationDocument.find(params[:id])
    raise ActiveRecord::RecordNotFound unless @document.kind == 'bank_statement'

    @filter = %w[pending flagged all].include?(params[:show]) ? params[:show] : 'pending'
    scope = BankStatementLine.for_document(@document.id)
    @counts = scope.reorder(nil).group(:status).count
    @flagged_count = scope.flagged.pending.count
    @lines = case @filter
    when 'all' then scope.to_a
    when 'flagged' then scope.flagged.pending.to_a
    else scope.pending.to_a
    end
    @vendors = Purchasing::Vendor.ordered.to_a
    @can_write = Current.user.can?('finance.write')
  end

  def decide
    document = ReconciliationDocument.find(params[:id])
    decisions = params.fetch(:decisions, {}).permit!.to_h.reject { |_, v| v.blank? || v == 'leave' }
    lines = BankStatementLine.for_document(document.id).pending.where(id: decisions.keys).index_by { |l| l.id.to_s }
    done = Hash.new(0)
    BankStatementLine.transaction do
      decisions.each do |id, choice|
        line = lines[id] or next
        apply(line, choice, document, done)
      end
    end
    ActivityLogger.log('bank_statement_decided', subject: document, details: done.map { |k, v| "#{v} #{k}" }.join(', ').presence || 'no changes')
    redirect_to bank_statement_path(document.id, show: params[:show]),
      notice: done.empty? ? 'Nothing was changed.' : "Recorded: #{done.map { |k, v| "#{v} #{k}" }.join(', ')}."
  rescue BankStatementImport::Error => e
    redirect_to bank_statement_path(params[:id]), alert: "Nothing was saved: #{e.message}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to bank_statement_path(params[:id]), alert: "Nothing was saved: #{e.record.errors.full_messages.to_sentence}."
  end

  private

  def apply(line, choice, document, done)
    kind, value = choice.split(':', 2)
    note = "From bank statement #{document.filename} line #{line.line_no}"
    case kind
    when 'ignore'
      line.decide!(status: 'ignored', user: Current.user)
      done['ignored'] += 1
    when 'expense'
      raise BankStatementImport::Error, 'Only withdrawals can be recorded as an expense, with a valid category.' unless line.money_out? && Finance::Expense::CATEGORIES.include?(value)

      expense = Finance::Expense.create!(payee: line.description.first(100), category: value, amount_cents: line.out_cents, incurred_on: line.posted_on,
        method: 'bank_transfer', reference: "bank-line-#{line.id}", notes: note)
      entry = Finance::Posting.expense(expense, created_by: Current.user)
      line.decide!(status: 'recorded', user: Current.user, expense: expense, journal_entry: entry)
      ActivityLogger.log('expense_recorded', subject: expense, details: "$#{format('%.2f', line.out_cents / 100.0)} · #{value} · from bank statement")
      note_approved_period(line.posted_on, 'Expense')
      done['expense(s)'] += 1
    when 'payment'
      vendor = Purchasing::Vendor.find(value)
      raise BankStatementImport::Error, 'Only withdrawals can be recorded as a vendor payment.' unless line.money_out?

      payment = Finance::VendorPayment.new(vendor: vendor, amount_cents: line.out_cents, paid_on: line.posted_on, method: 'bank_transfer',
        reference: "bank-line-#{line.id}", notes: note)
      Finance::VendorPaymentWorkflow.save!(payment, actor: Current.user)
      entry = Finance::Posting.vendor_payment(payment, created_by: Current.user)
      line.decide!(status: 'recorded', user: Current.user, vendor_payment: payment, journal_entry: entry)
      ActivityLogger.log('vendor_payment', subject: vendor, details: "$#{format('%.2f', line.out_cents / 100.0)} · from bank statement")
      note_approved_period(line.posted_on, 'Vendor payment')
      done['vendor payment(s)'] += 1
    end
  end
end
