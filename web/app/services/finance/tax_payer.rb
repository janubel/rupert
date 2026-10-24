# frozen_string_literal: true

module Finance
  # The business filing the 1099s (the payer): name, address, phone and EIN, kept as encrypted workspace settings.
  class TaxPayer
    include ActiveModel::Model
    include ActiveModel::Attributes

    FIELDS = { name: 'TAX_PAYER_NAME', street: 'TAX_PAYER_STREET', city: 'TAX_PAYER_CITY', state: 'TAX_PAYER_STATE',
               zip: 'TAX_PAYER_ZIP', phone: 'TAX_PAYER_PHONE', tin: 'TAX_PAYER_TIN' }.freeze
    FIELDS.each_key { |field| attribute field, :string }

    validates :name, :street, :city, presence: true
    validates :state, format: { with: /\A[A-Z]{2}\z/ }
    validates :zip, format: { with: /\A\d{5}(-\d{4})?\z/ }
    validates :tin, format: { with: /\A\d{9}\z/, message: 'must be the 9-digit EIN' }

    def self.load = new(FIELDS.to_h { |field, key| [field, EnvStore.fetch(key, '').presence] })

    def complete? = valid?
    def masked_tin = tin.to_s.length == 9 ? "••-•••#{tin.last(4)}" : nil
    def formatted_tin = tin.to_s.length == 9 ? "#{tin[0, 2]}-#{tin[2..]}" : nil
    def city_line = [city, [state, zip].compact_blank.join(' ')].compact_blank.join(', ')

    # Saves what was entered; a blank EIN keeps the one on file.
    def update(attributes)
      current = self.class.load
      attributes = attributes.to_h.symbolize_keys.slice(*FIELDS.keys).transform_values { |value| value.to_s.strip }
      attributes[:tin] = attributes[:tin].to_s.gsub(/\D/, '')
      attributes[:tin] = current.tin if attributes[:tin].blank?
      attributes[:state] = attributes[:state].to_s.upcase
      assign_attributes(attributes)
      return false unless valid?

      FIELDS.each { |field, key| EnvStore.set(key, public_send(field).presence) }
      true
    end
  end
end
