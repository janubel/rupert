# frozen_string_literal: true

module Finance
  # Expense register: money-out records with categories.
  class ExpensesController < AuthenticatedController
    include ApprovedPeriodNotice
    before_action :set_expense, only: %i[edit update destroy restore]

    def index
      authorize(:module, :finance_read?)
      @category = params[:category].presence || 'all'
      @range_days = params[:days].present? ? params[:days].to_i.clamp(7, 365) : 90
      @from = Date.current - (@range_days - 1)
      @through = Date.current
      active = Finance::Expense.where(incurred_on: @from..@through)
      @category = Finance::Expense::CATEGORIES.include?(params[:category]) ? params[:category] : 'all'
      active = active.by_category(@category)
      @by_category = active.group(:category).sum(:amount_cents).sort_by { |_key, value| -value }.first(3)
      @include_deleted = params[:include_deleted] == '1'
      @total_cents = active.sum(:amount_cents)
      @entry_count = active.count
      scope = @include_deleted ? active.with_discarded : active
      @removed_count = scope.count - @entry_count
      response.headers['Cache-Control'] = 'private, no-store'
      if request.format.csv?
        send_data expenses_csv(scope.includes(:vendor).order(incurred_on: :desc, created_at: :desc)), filename: "expenses-#{@range_days}d.csv"
        return
      end
      @pagy, @expenses = pagy(scope.includes(:vendor).order(incurred_on: :desc, created_at: :desc), items: 50)
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
      if @expense.save
        note_approved_period(@expense.incurred_on, 'Expense')
        Finance::Posting.expense(@expense, created_by: Current.user)
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
      old_date = @expense.incurred_on
      if @expense.update(expense_params)
        repost_expense(@expense)
        ActivityLogger.log('expense_updated', subject: @expense, details: change_summary(@expense))
        [old_date, @expense.incurred_on].uniq.each { |date| note_approved_period(date, 'Expense') }
        redirect_to(finance_expenses_path, notice: 'Expense updated.')
      else
        @vendors = Purchasing::Vendor.ordered
        @accounts = Finance::Account.active.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :finance_write?)
      return redirect_to(finance_expenses_path, alert: @expense.errors.full_messages.to_sentence.presence || 'Nothing was changed.') unless @expense.discard

      Finance::Posting.void_source('Finance::Expense', @expense.id)
      ActivityLogger.log('expense_deleted', subject: @expense, details: "$#{format('%.2f', @expense.amount_cents / 100.0)} · #{@expense.category} · #{@expense.incurred_on}")
      note_approved_period(@expense.incurred_on, 'Expense')
      redirect_to(finance_expenses_path, notice: 'Expense removed.')
    end

    # Restore a discarded expense back into the register.
    def restore
      authorize(:module, :finance_write?)
      return redirect_to(finance_expenses_path, alert: @expense.errors.full_messages.to_sentence.presence || 'Nothing was changed.') unless @expense.undiscard

      Finance::Posting.expense(@expense, created_by: Current.user)
      ActivityLogger.log('expense_restored', subject: @expense)
      note_approved_period(@expense.incurred_on, 'Expense')
      redirect_to(finance_expenses_path, notice: 'Expense restored.')
    end

    private

    # Void the prior posting and re-post when a money-bearing field changed, so
    # the ledger always reflects the current expense.
    def repost_expense(expense)
      financial = %w[amount_cents category method incurred_on account_id]
      return unless (expense.saved_changes.keys & financial).any?

      Finance::Posting.void_source('Finance::Expense', expense.id)
      Finance::Posting.expense(expense, created_by: Current.user)
    end

    def expenses_csv(expenses)
      require 'csv'
      CSV.generate do |csv|
        csv << %w[Date Payee Category Method Amount Vendor Reference Notes State]
        expenses.each do |expense|
          csv << [
            expense.incurred_on,
            expense.payee,
            expense.category,
            expense.method,
            expense.amount_cents / 100.0,
            expense.vendor&.name,
            expense.reference,
            expense.notes,
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
