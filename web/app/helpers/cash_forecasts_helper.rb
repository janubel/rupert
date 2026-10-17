# frozen_string_literal: true

module CashForecastsHelper
  # Ties the server error to the one field it names.
  def cash_forecast_field_error(id)
    @error_field == id ? { 'aria-invalid': true, 'aria-describedby': 'cash-forecast-error' } : {}
  end

  def cash_forecast_week_dates(day, index)
    "#{day.next_day(index * 7 + 1).strftime('%b %-d')} – #{day.next_day((index + 1) * 7).strftime('%b %-d')}"
  end
end
