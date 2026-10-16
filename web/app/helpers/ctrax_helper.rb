# frozen_string_literal: true

module CtraxHelper
  def ctrax_money(value)
    value.nil? ? 'Unknown' : number_to_currency(BigDecimal(value.to_s) / 100)
  end
end
