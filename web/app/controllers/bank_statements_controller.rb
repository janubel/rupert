# frozen_string_literal: true

# Upload a bank statement CSV, then decide line by line what each withdrawal
# is. Nothing becomes an expense or vendor payment until a person chooses it.
class BankStatementsController < AuthenticatedController
  include ApprovedPeriodNotice

  # Lines per review page. Each pending line submits a select and, for a
  # deposit, a name field; Rack caps a form at 4,096 fields, so a 5,000-line
  # statement cannot be saved from one page.
  PAGE_SIZE = 200

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
    OpsLog.import(kind: 'bank_statement', outcome: 'ok', rows: result[:created], duplicates: result[:duplicates], document_id: result[:document].id)
    ActivityLogger.log('bank_statement_uploaded', subject: result[:document],
      details: "#{params[:account_label].to_s.strip}: #{result[:created]} new line(s), #{result[:duplicates]} already seen, #{result[:from]}..#{result[:to]}")
    notice = "#{result[:created]} line(s) ready to review"
    notice += "; #{result[:duplicates]} already seen and skipped" if result[:duplicates].positive?
    redirect_to bank_statement_path(result[:document].id), notice: "#{notice}. The original file is retained unchanged."
  rescue BankStatementImport::Error, ReconciliationEvidence::Error => e
    OpsLog.import(kind: 'bank_statement', outcome: 'rejected', error_class: e.class.name)
    upload_failed(e.message)
  rescue ActiveRecord::StatementInvalid => e
    raise unless database_busy?(e)

    OpsLog.import(kind: 'bank_statement', outcome: 'rejected', error_class: 'DatabaseBusy')
    upload_failed('The database is busy with another import or sync. Try again in a minute.')
  end

  def show
    @document = ReconciliationDocument.find(params[:id])
    raise ActiveRecord::RecordNotFound unless @document.kind == 'bank_statement'

    @filter = %w[pending flagged all].include?(params[:show]) ? params[:show] : 'pending'
    scope = BankStatementLine.for_document(@document.id)
    @counts = scope.reorder(nil).group(:status).count
    @flagged_count = scope.flagged.pending.count
    listed = case @filter
    when 'all' then scope
    when 'flagged' then scope.flagged.pending
    else scope.pending
    end
    @pagy, @lines = pagy(:offset, listed, page: [params[:page].to_i, 1].max, limit: PAGE_SIZE)
    @vendors = Purchasing::Vendor.ordered.to_a
    @can_write = Current.user.can?('finance.write')
    @expenses_by_id = Finance::Expense.where(id: @lines.filter_map(&:expense_id)).index_by(&:id)
    catalog = Finance::ExpenseCategory.catalog
    @expense_options = catalog.select(&:active).map { |c| [c.name, "expense:#{c.key}"] }
    @category_labels = catalog.to_h { |c| [c.key, c.name] }
    @suggestions = @lines.to_h { |line| [line.id, line.suggested_category(catalog)] }
  end

  def decide
    document = ReconciliationDocument.find(params[:id])
    decisions = params.fetch(:decisions, {}).permit!.to_h.reject { |_, v| v.blank? || v == 'leave' }
    payers = params.fetch(:payers, {}).permit!.to_h.transform_values { |v| v.to_s.squish.first(120) }
    lines = BankStatementLine.for_document(document.id).pending.where(id: decisions.keys).index_by { |l| l.id.to_s }
    done = Hash.new(0)
    BankStatementLine.transaction do
      Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      name_payers(document, payers, done)
      decisions.each do |id, choice|
        line = lines[id] or next
        apply(line, choice, document, done)
      end
    end
    stale = (decisions.keys - lines.keys).size
    ActivityLogger.log('bank_statement_decided', subject: document, details: done.map { |k, v| "#{v} #{k}" }.join(', ').presence || 'no changes')
    notice = done.empty? ? 'Nothing was changed.' : "Recorded: #{done.map { |k, v| "#{v} #{k}" }.join(', ')}."
    notice += " #{stale} line(s) were already decided elsewhere and were left as they are." if stale.positive?
    redirect_to bank_statement_path(document.id, show: params[:show], page: params[:page].presence), notice: notice
  rescue BankStatementImport::Error => e
    redirect_to bank_statement_path(params[:id]), alert: "Nothing was saved: #{e.message}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to bank_statement_path(params[:id]), alert: "Nothing was saved: #{e.record.errors.full_messages.to_sentence}."
  end

  private

  def upload_failed(message)
    @statements = []
    @documents = {}
    @can_write = true
    @form_error = message
    render :index, status: :unprocessable_entity
  end

  # SQLite has one writer; a long sync or import elsewhere surfaces here as a
  # busy/locked error after the busy timeout rather than as a broken file.
  def database_busy?(error)
    error.is_a?(ActiveRecord::StatementTimeout) || error.cause.is_a?(SQLite3::BusyException) || error.message.match?(/database is (busy|locked)/i)
  end

  # "Received from" names for deposits. Editable before or after a decision;
  # only changed names are written.
  def name_payers(document, payers, done)
    return if payers.empty?

    BankStatementLine.for_document(document.id).where(id: payers.keys).find_each do |line|
      name = payers[line.id.to_s].presence
      next if !line.money_in? || line.counterparty.to_s == name.to_s

      line.update!(counterparty: name)
      done['name(s) saved'] += 1
    end
  end

  def apply(line, choice, document, done)
    kind, value = choice.split(':', 2)
    mapping = BankStatementAccount.find_by(account_label: line.account_label)
    if %w[expense payment].include?(kind) && mapping && mapping.ledger_account.code != '1100'
      raise BankStatementImport::Error, 'Statement expense and vendor-payment creation currently posts to Checking (1100). For this mapped account, create the correct journal entry and confirm its match in Bank reconciliation. Nothing was recorded.'
    end
    note = "From bank statement #{document.filename} line #{line.line_no}"
    case kind
    when 'ignore'
      line.decide!(status: 'ignored', user: Current.user)
      done['ignored'] += 1
    when 'deposit'
      raise BankStatementImport::Error, "Line #{line.line_no} is not a deposit." unless line.money_in?

      # Accepted as money received: never an expense, no ledger entry created here.
      line.decide!(status: 'ignored', user: Current.user, category: 'deposit_received')
      done['deposit(s) accepted'] += 1
    when 'expense'
      raise BankStatementImport::Error, 'Only withdrawals can be recorded as an expense, with a valid category.' unless line.money_out? && Finance::ExpenseCategory.active_keys.include?(value)

      expense = Finance::Expense.create!(payee: line.description.first(100), category: value, amount_cents: line.out_cents, incurred_on: line.posted_on,
        method: 'bank_transfer', reference: "bank-line-#{line.id}", notes: note)
      entry = Finance::Posting.expense(expense, created_by: Current.user)
      line.decide!(status: 'recorded', user: Current.user, expense: expense, journal_entry: entry)
      ActivityLogger.log('expense_recorded', subject: expense, details: "$#{format('%.2f', line.out_cents / 100.0)} · #{value} · from bank statement")
      note_approved_period(line.posted_on, 'Expense')
      done['expense(s)'] += 1
    when 'payment'
      vendor = Purchasing::Vendor.find_by(id: value)
      raise BankStatementImport::Error, 'Choose an existing vendor for each vendor payment.' unless vendor
      raise BankStatementImport::Error, 'Only withdrawals can be recorded as a vendor payment.' unless line.money_out?

      payment = Finance::VendorPayment.new(vendor: vendor, amount_cents: line.out_cents, paid_on: line.posted_on, method: 'bank_transfer',
        reference: "bank-line-#{line.id}", notes: note)
      Finance::VendorPaymentWorkflow.save!(payment, actor: Current.user)
      entry = Finance::Posting.vendor_payment(payment, created_by: Current.user)
      line.decide!(status: 'recorded', user: Current.user, vendor_payment: payment, journal_entry: entry)
      ActivityLogger.log('vendor_payment', subject: vendor, details: "$#{format('%.2f', line.out_cents / 100.0)} · from bank statement")
      note_approved_period(line.posted_on, 'Vendor payment')
      done['vendor payment(s)'] += 1
    else
      raise BankStatementImport::Error, "Line #{line.line_no} has an unrecognised choice."
    end
  end
end
