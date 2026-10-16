# frozen_string_literal: true

module CtraxHelper
  def ctrax_money(value, currency: 'USD')
    value.nil? ? 'Unknown' : number_to_currency(BigDecimal(value.to_s) / 100, unit: currency == 'USD' ? '$' : "#{currency} ")
  end
end
