# frozen_string_literal: true

class LiveCommissionsController < AuthenticatedController
  def show
    authorize(:module, :payroll_read?)
    response.headers['Cache-Control'] = 'no-store'
    @source = params[:source].presence || 'shopify'
    @currency = params[:currency].presence || 'USD'
    @preview = CommissionPreview.new(start_date: Date.current, end_date: Date.current, source: @source, currency: @currency)
    @sources = SourceSyncStatus.all.select { |source| %w[shopify swipesimple authorize_net].include?(source[:key]) }
    @last_order_at = Core::Order.where(source: @source, currency: @currency).maximum(:updated_at)
    @shift_count = ClockShift.where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', Time.current, Time.current.beginning_of_day).count
    render :show, layout: false
  rescue CommissionPreview::Error => e
    @preview_error = e.message
    render :show, status: :unprocessable_entity, layout: false
  end
end
