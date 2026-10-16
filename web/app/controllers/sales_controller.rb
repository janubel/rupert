# frozen_string_literal: true

class SalesController < AuthenticatedController
  def index
    authorize(:module, :sales_read?)
    response.headers['Cache-Control'] = 'private, no-store'
    @date = report_date
    @window_days = params[:window].present? ? params[:window].to_i.clamp(1, 365) : 30
    @source = params[:source].presence || 'all'
    @status = %w[paid fulfilled placed cancelled refunded].include?(params[:status]) ? params[:status] : 'all'
    @sources = (%w[shopify ctrax square rupert_pos] | Core::Order.distinct.pluck(:source)).sort
    @sales = DashboardSales.new(days: @window_days, now: @date.end_of_day)
    @day_total_cents = @sales.gross(since: @date.beginning_of_day, source: selected_source)
    @day_count = @sales.count(since: @date.beginning_of_day, source: selected_source)
    @total_cents = @sales.gross(source: selected_source)
    @sales_count = @sales.count(source: selected_source)
    @revenue_series = @sales.daily(source: selected_source)
    @hourly_series = @sales.hourly(source: selected_source)
    @source_groups = @sales.groups(since: @date.beginning_of_day, source: selected_source)
    @freshness = DashboardPresenter.new(user: Current.user).sales_freshness
    journal = Core::Order.on_day(@date).by_source(selected_source)
    journal = journal.where(status: @status) unless @status == 'all'
    @pagy, @day_sales = pagy(journal.includes(:fulfillments, :location).order(occurred_at: :asc, id: :asc), items: 50)
    @hourly = hourly_pivot(@date, selected_source)
  end

  def print
    authorize(:module, :sales_read?)
    @date = report_date
    @doc = params[:doc].to_s == 'invoice' ? 'invoice' : 'packing_slip'
    @orders = Core::Order.on_day(@date).by_source(params[:source]).includes(:customer, :order_lines, :fulfillments).order(occurred_at: :asc)
    @orders = @orders.where(status: params[:status]) if %w[paid fulfilled placed cancelled refunded].include?(params[:status])
    render(layout: 'print')
  end

  private

  def report_date
    Date.iso8601(params[:date].to_s)
  rescue Date::Error
    Date.current
  end

  def selected_source
    @source == 'all' ? nil : @source
  end

  def hourly_pivot(date, source)
    orders = Core::Order.on_day(date).by_source(source).where(status: %w[paid fulfilled], currency: 'USD').includes(:location)
    names = orders.map { |order| order.location&.name || 'Unknown' }.uniq
    rows = (0..23).map do |hour|
      { hour: hour, label: date.in_time_zone.change(hour: hour).strftime('%-I %p'), cells: names.index_with { { cents: 0, count: 0 } } }
    end
    orders.each do |order|
      cell = rows[order.occurred_at.in_time_zone.hour][:cells][order.location&.name || 'Unknown']
      cell[:cents] += order.gross_cents.to_i
      cell[:count] += 1
    end
    rows
  end
end
