# frozen_string_literal: true

module FinanceRegisterPeriod
  private

  def load_finance_register_period
    @range_days = params[:days].present? ? params[:days].to_i.clamp(7, 365) : 90
    @from = Date.current - (@range_days - 1)
    @through = Date.current
    return if params[:month].blank?

    unless params[:month].to_s.match?(/\A20\d{2}-\d{2}\z/)
      raise Date::Error
    end
    first = Date.iso8601("#{params[:month]}-01")
    @month = first.strftime('%Y-%m')
    @from, @through = first, first.end_of_month
  rescue Date::Error
    flash.now[:alert] = 'Choose a valid month in YYYY-MM format. Showing the recent date range.'
  end
end
