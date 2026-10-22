# frozen_string_literal: true

module Finance
  # Expense register: money-out records with categories.
  class ExpensesController < AuthenticatedController
    include ApprovedPeriodNotice
    include FinanceRegister
    before_action :set_expense, only: %i[edit update destroy restore]

    def index
      authorize(:module, :finance_read?)
      @from, @through = register_window
      @category = Finance::ExpenseCategory.known_keys.include?(params[:category]) ? params[:category] : 'all'
      @q = params[:q].to_s.strip.first(100)
      @min_cents = register_cents(params[:min])
      @max_cents = register_cents(params[:max])
      @filter_problem = amount_filter_problem
      active = Finance::Expense.where(incurred_on: @from..@through).by_category(@category)
      active = search(active)
      active = active.where('expenses.amount_cents >= ?', @min_cents) if @min_cents
      active = active.where('expenses.amount_cents <= ?', @max_cents) if @max_cents
      @by_category = active.group(:category).sum(:amount_cents).sort_by { |_key, value| -value }.first(3)
      @include_deleted = params[:include_deleted] != '0'
      @total_cents = active.sum(:amount_cents)
      @entry_count = active.count
      scope = @include_deleted ? active.with_discarded : active
      @removed_count = scope.count - @entry_count
      response.headers['Cache-Control'] = 'private, no-store'
      ordered = scope.includes(:vendor).order(incurred_on: :desc, created_at: :desc)
      if request.format.csv?
        log_export('Expense register CSV', (@month || "#{@from} to #{@through}").to_s)
        send_data expenses_csv(ordered), filename: "expenses-#{@month || "#{@from}-#{@through}"}.csv", type: 'text/csv'
        return
      end
      @pagy, @expenses = pagy(:offset, ordered, limit: 50)
      @activity = register_activity('Finance::Expense', @expenses.map(&:id))
      @locks = register_locks
      @can_write = Current.user.can?('finance.write')
    end

    def new
      authorize(:module, :finance_write?)
      @expense = Finance::Expense.new(incurred_on: Date.current)
      @vendors = Purchasing::Vendor.ordered
      @accounts = Finance::Account.active.ordered
    end

    def create
      authorize(:module, :finance_write?)
      @expense = Finance::Expense.new(expense_params)
      if save_with_posting { @expense.save && post_expense(@expense) }
        note_approved_period(@expense.incurred_on, 'Expense')
        ActivityLogger.log(
          'expense_recorded',
          subject: @expense,
          details: "$#{format('%.2f', @expense.amount_cents / 100.0)} · #{@expense.category}"
        )
        redirect_to(finance_expenses_path, notice: 'Expense recorded.')
      else
        @vendors = Purchasing::Vendor.ordered
        @accounts = Finance::Account.active.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :finance_write?)
      @vendors = Purchasing::Vendor.ordered
      @accounts = Finance::Account.active.ordered
    end

    def update
      authorize(:module, :finance_write?)
      if @expense.discarded?
        redirect_to(finance_expenses_path, alert: 'Restore this expense before editing it.')
        return
      end
      old_date = @expense.incurred_on
      if save_with_posting { @expense.update(expense_params) && repost_expense(@expense) }
        ActivityLogger.log('expense_updated', subject: @expense, details: change_summary(@expense))
        [old_date, @expense.incurred_on].uniq.each { |date| note_approved_period(date, 'Expense') }
        redirect_to(safe_return_to || finance_expenses_path, notice: 'Expense updated.')
      else
        @vendors = Purchasing::Vendor.ordered
        @accounts = Finance::Account.active.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :finance_write?)
      removed = save_with_posting { @expense.discard && (Finance::Posting.void_source('Finance::Expense', @expense.id) || true) }
      return redirect_to(finance_expenses_path, alert: @expense.errors.full_messages.to_sentence.presence || 'Nothing was changed.') unless removed

      ActivityLogger.log('expense_deleted', subject: @expense, details: "$#{format('%.2f', @expense.amount_cents / 100.0)} · #{@expense.category} · #{@expense.incurred_on}")
      note_approved_period(@expense.incurred_on, 'Expense')
      redirect_to(finance_expenses_path, notice: 'Expense removed.')
    end

    # Restore a discarded expense back into the register.
    def restore
      authorize(:module, :finance_write?)
      restored = save_with_posting { @expense.undiscard && post_expense(@expense) }
      return redirect_to(finance_expenses_path, alert: @expense.errors.full_messages.to_sentence.presence || 'Nothing was changed.') unless restored

      ActivityLogger.log('expense_restored', subject: @expense)
      note_approved_period(@expense.incurred_on, 'Expense')
      redirect_to(finance_expenses_path, notice: 'Expense restored.')
    end

    private

    # Void the prior posting and re-post when a money-bearing field changed, so
    # the ledger always reflects the current expense.
    # Only same-site paths, so a crafted link can't send people elsewhere.
    def safe_return_to
      path = params[:return_to].to_s
      path if path.start_with?('/') && !path.start_with?('//') && !path.include?('\\')
    end

    def repost_expense(expense)
      return true unless expense.kept?

      financial = %w[amount_cents category method incurred_on account_id]
      return true unless (expense.saved_changes.keys & financial).any?

      Finance::Posting.void_source('Finance::Expense', expense.id)
      post_expense(expense)
    end

    def post_expense(expense)
      Finance::Posting.expense(expense, created_by: Current.user)
      true
    end

    # Runs the record change and its ledger posting as one unit. If either
    # fails the whole thing is rolled back and the reason is put on the record,
    # so an expense is never saved without its ledger entry.
    def posting_failure_message(error)
      case error
      when ActiveRecord::RecordInvalid then error.record.errors.full_messages.to_sentence
      when ActiveRecord::RecordNotFound then 'The expense could not be posted. Check the chart of accounts and try again.'
      else error.message
      end
    end

    def save_with_posting
      ok = false
      Finance::Expense.transaction do
        Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
        @expense.reload if @expense.persisted?
        ok = yield
        raise ActiveRecord::Rollback unless ok
      end
      ok
    rescue Finance::Posting::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @expense.errors.add(:base, posting_failure_message(e))
      false
    end

    def search(scope)
      return scope if @q.blank?

      like = register_like(@q)
      scope.left_joins(:vendor).where(
        'LOWER(expenses.payee) LIKE :q OR LOWER(expenses.reference) LIKE :q OR LOWER(expenses.notes) LIKE :q OR LOWER(vendors.name) LIKE :q', q: like
      )
    end

    def amount_filter_problem
      if params[:min].present? && @min_cents.nil? || params[:max].present? && @max_cents.nil?
        'An amount filter was ignored: enter dollars as digits with up to two decimals, for example 25.50.'
      elsif @min_cents && @max_cents && @min_cents > @max_cents
        'The minimum amount is larger than the maximum, so nothing can match.'
      end
    end

    # Text cells are neutralised so a payee such as "=HYPERLINK(...)" cannot
    # run as a spreadsheet formula. Amounts are exact decimals in USD.
    def expenses_csv(expenses)
      require 'csv'
      safe = FinanceHelper.method(:csv_safe)
      CSV.generate do |csv|
        csv << %w[Date Payee Category Method Amount Currency Vendor Reference Notes State]
        expenses.each do |expense|
          csv << [
            expense.incurred_on,
            safe.call(expense.payee),
            expense.category,
            expense.method,
            FinanceHelper.cents_to_decimal(expense.amount_cents),
            'USD',
            safe.call(expense.vendor&.name),
            safe.call(expense.reference),
            safe.call(expense.notes),
            expense.discarded? ? 'Removed' : 'Active'
          ]
        end
      end
    end

    def set_expense
      @expense = Finance::Expense.unscoped.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def expense_params
      params.require(:expense).permit(:payee, :category, :amount, :incurred_on, :method, :reference, :notes, :vendor_id, :account_id)
    end
  end
end
