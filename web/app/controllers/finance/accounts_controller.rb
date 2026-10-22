# frozen_string_literal: true

module Finance
  # Accounts overview: payables (what we owe vendors) and receivables (what
  # customers owe us).
  class AccountsController < AuthenticatedController
    def show
      authorize(:module, :finance_read?)
      @payables = Purchasing::Payables.by_vendor
      @payables_total = @payables.sum { |row| row[:balance_cents] }
      @receivables = Core::Receivables.by_customer
      @receivable_groups = @receivables.group_by { |row| row[:currency] }
      @credits_total = @payables.sum { |row| [row[:paid_cents] - row[:owed_cents], 0].max }
      @committed_total = @payables.sum { |row| row[:committed_cents] }
      @payables_count = @payables.count { |row| row[:balance_cents].positive? }
      @receivables_count = @receivables.size
      @pagy, @receivables = pagy(:offset, @receivables, limit: 50)
      response.headers['Cache-Control'] = 'private, no-store'
    end
  end
end
