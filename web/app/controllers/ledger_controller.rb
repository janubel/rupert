# frozen_string_literal: true

class LedgerController < AuthenticatedController
  def index
    authorize(:module, :ledger_read?)
    response.headers['Cache-Control'] = 'private, no-store'
    @source = params[:source].presence || 'all'
    @window_days = params[:window].present? ? params[:window].to_i.clamp(1, 365) : 30
    @from = Date.current - (@window_days - 1)
    scope = LedgerEntry.where(occurredAt: @from.beginning_of_day..Time.current).by_source(@source)
    @sources = LedgerEntry.distinct.order(:source).pluck(:source)
    @currency_totals = scope.group(:currency).sum(:grossCents)
    @pagy, @entries = pagy(scope.order(occurredAt: :desc, id: :asc), items: 50)
  end
end
