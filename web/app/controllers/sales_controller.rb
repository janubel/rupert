# frozen_string_literal: true

# Daily sales journal ("spreadstyle" layout): every sale of a day listed in
# arrival order across the hour ladder, showing where each sale occurred.
class SalesController < AuthenticatedController
  def index
    authorize(:module, :sales_read?)

    @date = begin
      Date.parse(params[:date].to_s)
    rescue Date::Error
      Time.current.to_date
    end
    @window_days = params[:window].present? ? params[:window].to_i.clamp(1, 365) : 30

    since = Time.current - @window_days.days
    @source = params[:source].presence || 'all'
    source_scope = @source == 'all' ? nil : @source
    @sources = Core::Order.since(since).distinct.pluck(:source).sort

    sales_scope = Core::Order.since(since).by_source(source_scope)
    @total_cents = sales_scope.sum(:gross_cents)
    @sales_count = sales_scope.count

    @hourly = hourly_pivot(@date, source_scope)
    @day_sales = Core::Order.on_day(@date).by_source(source_scope).includes(:fulfillments,
      :location).order(occurred_at: :asc)
    @day_total_cents = @day_sales.sum(:gross_cents)
    @locations = Location.order(:name).pluck(:name, :id)
    presenter = DashboardPresenter.new(user: Current.user, include_ctrax: false)
    @revenue_series = presenter.revenue_series(days: @window_days, source: source_scope)
    @hourly_series = presenter.hourly_series(days: @window_days, source: source_scope)
    @source_breakdown = presenter.source_breakdown(days: @window_days)
  end

  # Batch print view: every order on a day as a packing slip (or invoice),
  # laid out one per page for the shipping desk.
  def print
    authorize(:module, :sales_read?)
    @date = params[:date].present? ? Date.parse(params[:date]) : Time.current.to_date
    @doc = params[:doc].to_s == 'invoice' ? 'invoice' : 'packing_slip'
    @orders = Core::Order.on_day(@date).includes(:customer, :order_lines, :fulfillments).order(occurred_at: :asc)
    render(layout: 'print')
  rescue ArgumentError
    redirect_to(sales_path, alert: 'Invalid date.')
  end

  private

  # rows: hour (9..21), columns: location name -> gross cents + count. Every
  # row carries the same column set so the header always renders, even when no
  # sales happened in the first hour.
  def hourly_pivot(date, source = nil)
    orders = Core::Order.on_day(date).by_source(source).includes(:location)
    names = orders.map { |o| o.location&.name || 'Unknown' }.uniq
    rows = (9..21).map do |h|
      { hour: h, label: Time.zone.parse("#{h}:00").strftime('%-I %p'), cells: names.to_h do |n|
        [n, { cents: 0, count: 0 }]
      end }
    end

    orders.group_by { |o| o.occurred_at.hour }.each do |hour, bucket|
      row = rows.find { |r| r[:hour] == hour }
      next unless row

      bucket.group_by { |o| o.location&.name || 'Unknown' }.each do |name, group|
        row[:cells][name][:cents] += group.sum(&:gross_cents)
        row[:cells][name][:count] += group.size
      end
    end
    rows
  end
end
