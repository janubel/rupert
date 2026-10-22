# frozen_string_literal: true

module Finance
  # One page for everything Rupert retains, by source. Read-only.
  class HistoryController < AuthenticatedController
    before_action -> { authorize(:module, :finance_read?) }
    before_action { response.headers['Cache-Control'] = 'private, no-store' }

    def show
      summary = HistorySummary.new
      @sources = summary.sources
      @years = summary.years.reverse
      @year = params[:year].to_s.match?(/\A\d{4}\z/) ? params[:year] : nil
      reconciliation = HistoryReconciliation.new
      @ledger_comparison = reconciliation.ledger
      @trial_balances = reconciliation.trial_balances
      @bank_comparisons = reconciliation.bank
    end
  end
end
