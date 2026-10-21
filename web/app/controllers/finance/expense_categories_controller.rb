# frozen_string_literal: true

module Finance
  # Edit the expense categories used by expenses, receipts and bank statement
  # decisions: rename, choose the ledger account each posts to, set keyword
  # hints for bank-line suggestions, add new ones or deactivate old ones.
  # Changing a category's ledger account applies to expenses posted from now
  # on; existing journal entries are not rewritten.
  class ExpenseCategoriesController < AuthenticatedController
    before_action -> { authorize(:module, :finance_read?) }
    before_action -> { authorize(:module, :finance_write?) }, except: :index
    before_action :set_category, only: %i[edit update]
    before_action :set_accounts, only: %i[new create edit update]

    def index
      @categories = ExpenseCategory.catalog
      @usage = Finance::Expense.unscoped.where(tenant_id: Current.tenant_id).group(:category).count
    end

    def new
      @category = ExpenseCategory.new(active: true, position: (ExpenseCategory.maximum(:position) || 0) + 10)
    end

    def create
      @category = ExpenseCategory.new(category_params)
      if @category.save
        ActivityLogger.log('expense_category_created', subject: @category, details: @category.name)
        redirect_to(finance_expense_categories_path, notice: "Added “#{@category.name}”.")
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit; end

    def update
      if @category.update(category_params)
        ActivityLogger.log('expense_category_updated', subject: @category, details: @category.saved_changes.keys.excluding('updated_at').join(', '))
        redirect_to(finance_expense_categories_path, notice: "Saved “#{@category.name}”.")
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    private

    def set_category
      ExpenseCategory.ensure_defaults!
      @category = ExpenseCategory.find(params[:id])
    end

    def set_accounts
      @accounts = Finance::Account.active.where(account_type: 'expense').ordered
    end

    def category_params
      permitted = params.require(:expense_category).permit(:name, :ledger_account_id, :keywords, :active, :position)
      permitted[:ledger_account_id] = nil if permitted[:ledger_account_id].blank?
      permitted
    end
  end
end
