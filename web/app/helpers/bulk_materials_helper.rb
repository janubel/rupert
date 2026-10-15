# frozen_string_literal: true

module BulkMaterialsHelper
  def bulk_mass_label(milligrams, unit = 'g')
    decimal = BigDecimal(milligrams.to_s) / BulkMass::FACTORS.fetch(unit)
    formatted = number_with_precision(decimal, precision: 6, strip_insignificant_zeros: true)
    "#{formatted} #{unit} · #{number_with_delimiter(milligrams)} mg"
  end
end
