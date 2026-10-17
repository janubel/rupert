# frozen_string_literal: true

module Finance
  # General ledger: the balanced journal entries that back the books. Entries
  # produced automatically by Finance::Posting are read-only here; this
  # controller also lets an accountant post a manual entry (an adjustment,
  # accrual, opening balance or owner draw) through the same balanced path.
  class JournalEntriesController < AuthenticatedController
    before_action -> { authorize(:module, :finance_write?) }, only: %i[new create reverse]

    def index
      authorize(:module, :finance_read?)
      @can_write = Current.user.can?('finance.write')
      @kind = JournalEntry::KINDS.include?(params[:kind]) ? params[:kind] : 'all'
      @from = parse_date(params[:from])
      @to = parse_date(params[:to])

      scope = JournalEntry.in_range(@from, @to).recent
      scope = scope.where(kind: @kind) if @kind != 'all'

      totals_scope = JournalEntry.in_range(@from, @to)
      totals_scope = totals_scope.where(kind: @kind) if @kind != 'all'
      entry_ids = totals_scope.pluck(:id)
      @totals = {
        entries: entry_ids.size,
        debits: entry_ids.any? ? JournalLine.where(journal_entry_id: entry_ids).sum(:debit_cents) : 0,
        credits: entry_ids.any? ? JournalLine.where(journal_entry_id: entry_ids).sum(:credit_cents) : 0
      }

      @pagy, @entries = pagy(scope, items: 50)
      response.headers['Cache-Control'] = 'private, no-store'
    end

    def show
      authorize(:module, :finance_read?)
      @entry = JournalEntry.includes(journal_lines: :account).find(params[:id])
      @creator = User.find_by(id: @entry.created_by_id) if @entry.created_by_id
      @reversal_of = JournalEntry.find_by(id: @entry.source_id) if @entry.source_type == 'Finance::JournalEntry'
      @reversed_by = JournalEntry.for_source('Finance::JournalEntry', @entry.id).posted.first
      @activity = ActivityLog.for_subject('Finance::JournalEntry', @entry.id).order(:created_at).to_a
      @lock = PeriodLock.lock_covering(@entry.posted_on)
      @can_write = Current.user.can?('finance.write')
      @source_link = source_link_for(@entry)
    end

    def new
      @entry = JournalEntry.new(posted_on: Date.current, kind: 'manual')
      @accounts = Finance::Account.active.ordered
      @form_lines = []
    end

    # Server validation is authoritative: every line is checked and reported
    # by number, and nothing is posted (or silently skipped) unless all of it
    # is valid. The submitted values are kept so nothing has to be retyped.
    def create
      @accounts = Finance::Account.active.ordered
      @form_lines = manual_line_params.map { |lp| lp.to_h.symbolize_keys }
      lines, @line_errors = build_lines(@form_lines)
      @entry = JournalEntry.new(kind: 'manual', posted_on: parse_date(params[:posted_on]), memo: params[:memo])
      return render_invalid(@line_errors.map { |e| e[:message] }.to_sentence) if @line_errors.any?

      @entry = JournalEntry.post!(kind: 'manual', posted_on: params[:posted_on], memo: params[:memo],
        lines: lines, created_by: Current.user)
      ActivityLogger.log('journal_entry_created', subject: @entry,
        details: "Manual entry · #{@entry.debit_cents} cents on #{@entry.posted_on}")
      redirect_to finance_journal_entry_path(@entry), notice: 'Journal entry posted.'
    rescue ActiveRecord::RecordInvalid => e
      @entry = e.record.is_a?(JournalEntry) ? e.record : JournalEntry.new(kind: 'manual', posted_on: parse_date(params[:posted_on]), memo: params[:memo])
      render_invalid(e.record.errors.full_messages.to_sentence)
    end

    # Corrections are made by reversing, never by editing a posted entry. A
    # reversal is a new, dated entry with every debit and credit swapped. Only
    # hand-keyed entries can be reversed here: entries produced from an
    # expense, payment or sale are corrected on that record.
    def reverse
      authorize(:module, :finance_write?)
      original = JournalEntry.includes(:journal_lines).find(params[:id])
      reason = params[:reason].to_s.strip
      date = parse_date(params[:posted_on])
      problem = reversal_problem(original, date, reason)
      return redirect_to(finance_journal_entry_path(original), alert: problem) if problem

      reversal = JournalEntry.post!(
        kind: original.kind, posted_on: date, created_by: Current.user,
        source_type: 'Finance::JournalEntry', source_id: original.id,
        memo: "Reversal of entry ##{original.id} · #{reason}",
        lines: original.journal_lines.sort_by(&:position).map do |line|
          { account_id: line.account_id, debit_cents: line.credit_cents, credit_cents: line.debit_cents, memo: line.memo }
        end
      )
      ActivityLogger.log('journal_entry_reversed', subject: original,
        details: "Reversed by entry ##{reversal.id} dated #{date}: #{reason}")
      redirect_to finance_journal_entry_path(reversal), notice: "Entry ##{original.id} reversed by this entry."
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      message = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : 'This entry has already been reversed.'
      redirect_to finance_journal_entry_path(params[:id]), alert: "Not reversed. #{message}"
    end

    private

    # [label, path] for the record an entry was generated from, when there is a
    # page for it. Never raises for a source that has since been removed.
    def source_link_for(entry)
      case entry.source_type
      when 'Finance::Expense' then ['Expense register', finance_expenses_path(include_deleted: 1)]
      when 'Finance::VendorPayment' then ['Vendor payments register', finance_vendor_payments_path(include_deleted: 1)]
      when 'Core::Payment'
        order = Core::Payment.find_by(id: entry.source_id)&.order
        order ? ["Order #{order.order_number}", order_path(order)] : nil
      end
    end

    def manual_line_params
      Array(params.permit(lines: [:account_id, :debit, :credit, :memo]).to_h['lines'])
    end

    AMOUNT_FORMAT = /\A\d{1,9}(?:\.\d{1,2})?\z/

    # => [lines, errors]. A row with nothing entered is skipped; anything else
    # must be complete and unambiguous, or it is reported by line number.
    def build_lines(rows)
      errors = []
      lines = []
      active_ids = @accounts.map(&:id)
      rows.each_with_index do |row, index|
        next if row.values.all? { |v| v.to_s.strip.empty? }

        number = index + 1
        row_errors = line_errors(row, number, active_ids)
        errors.concat(row_errors.map { |m| { line: number, message: m } })
        next if row_errors.any?

        lines << { account_id: row[:account_id].to_i, debit_cents: to_cents(row[:debit]), credit_cents: to_cents(row[:credit]), memo: row[:memo] }
      end
      errors << { line: nil, message: 'Enter at least two lines: a debit and a credit.' } if errors.empty? && lines.size < 2
      errors.concat(balance_errors(lines)) if errors.empty?
      errors << { line: nil, message: 'Enter a valid date.' } if parse_date(params[:posted_on]).nil?
      [lines, errors]
    end

    def line_errors(row, number, active_ids)
      found = []
      debit = row[:debit].to_s.strip
      credit = row[:credit].to_s.strip
      found << "Line #{number}: choose an account." if row[:account_id].blank?
      found << "Line #{number}: that account is archived or does not exist." if row[:account_id].present? && !active_ids.include?(row[:account_id].to_i)
      found << "Line #{number}: enter a debit or a credit amount." if debit.empty? && credit.empty?
      found << "Line #{number}: use either Debit or Credit, not both." if debit.present? && credit.present?
      [['debit', debit], ['credit', credit]].each do |side, text|
        next if text.empty? || text.match?(AMOUNT_FORMAT)

        found << "Line #{number}: #{side} \"#{text.first(20)}\" is not an amount. Use digits with up to two decimals, no $ or commas."
      end
      found << "Line #{number}: the amount must be more than $0.00." if [debit, credit].any? { |t| t.match?(AMOUNT_FORMAT) && to_cents(t).zero? }
      found
    end

    def balance_errors(lines)
      debits = lines.sum { |l| l[:debit_cents] }
      credits = lines.sum { |l| l[:credit_cents] }
      return [] if debits == credits

      [{ line: nil, message: "Out of balance by #{helpers.finance_money_text((debits - credits).abs)}: " \
                             "debits #{helpers.finance_money_text(debits)}, credits #{helpers.finance_money_text(credits)}. Nothing was posted." }]
    end

    def to_cents(value)
      text = value.to_s.strip
      return 0 unless text.match?(AMOUNT_FORMAT)

      (BigDecimal(text) * 100).to_i
    end

    def render_invalid(message)
      @form_error = message
      render :new, status: :unprocessable_entity
    end

    def reversal_problem(original, date, reason)
      return 'Only hand-keyed entries can be reversed here. Correct the expense, payment or sale it came from instead.' unless %w[manual opening].include?(original.kind)
      return 'This entry is void.' if original.void?
      return 'Enter the date of the reversal.' if date.nil?
      return 'Enter a reason for the reversal.' if reason.empty?
      return 'This entry has already been reversed.' if JournalEntry.for_source('Finance::JournalEntry', original.id).posted.exists?

      nil
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end
  end
end
