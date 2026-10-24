# frozen_string_literal: true

require 'bigdecimal'

module Ctrax
  class StockSync
    def self.call(connection:)
      SyncObservability.observe('ctrax', 'stock') { new(connection).call }
    end

    def initialize(connection)
      @connection = connection
    end

    def call
      raise Client::Error, :invalid unless @connection.provider == 'ctrax' && @connection.persisted? &&
                                           @connection.vendor_approved && @connection.credentials_saved? && @connection.tenant_id == Current.tenant_id

      version = @connection.lock_version
      credentials = @connection.credential_values
      started = Time.current
      client = Client.new(credentials)
      # Fetch and validate every page before publishing any store's snapshot.
      snapshots = client.stores.map do |store|
        store.merge(records: client.stock(store[:id]).map { |row| normalize(row, master_products: client.master_products?) })
      end
      @connection.with_lock do
        raise Client::Error, :response unless @connection.lock_version == version

        snapshots.each do |store|
          external_id = "#{URI(credentials.fetch('api_url')).host}/#{store[:id]}"
          location = Location.find_or_initialize_by(source: 'ctrax', externalId: external_id)
          location.assign_attributes(name: store[:name], active: true, syncedAt: started)
          location.save!
          snapshot = CtraxStockSnapshot.find_or_initialize_by(location_id: location.id)
          raise Client::Error, :response if snapshot.captured_at && snapshot.captured_at > started

          snapshot.update!(api_origin: credentials.fetch('api_url'), store_id: store[:id],
            captured_at: started, records_json: store[:records])
        end
        # This also invalidates concurrent older syncs/checks without holding a
        # database transaction open during network requests.
        @connection.update!(last_check_status: 'verified', last_checked_at: Time.current,
          last_check_message: "C-Trax stock read completed: #{snapshots.size} stores, #{snapshots.sum do |store|
                              store[:records].size
                            end} variants.")
      end
      { stores: snapshots.size, variants: snapshots.sum { |store| store[:records].size } }
    rescue Client::Error => e
      if version
        PosConnection.where(id: @connection.id, lock_version: version).update_all(last_check_status: 'failed',
          last_check_message: e.message, last_checked_at: Time.current, updated_at: Time.current, lock_version: version + 1)
      end
      raise
    end

    private

    def normalize(row, master_products:)
      overrides = master_products ? row['attribute_store_overrides'] : nil
      raise Client::Error, :response unless overrides.nil? || overrides.is_a?(Hash)

      effective = ->(key) { overrides && !overrides[key].nil? ? overrides[key] : row[key] }
      sku = text(effective.call('sku'), 255)
      quantity = row.dig('store_stock', 'quantity')
      quantity = quantity.to_s if quantity.is_a?(Numeric)
      unless quantity.nil? || (quantity.is_a?(String) && quantity.match?(/\A-?\d{1,12}(?:\.\d{1,6})?\z/))
        raise Client::Error, :response
      end

      manage_stock = effective.call('manage_stock')
      manage_stock = true if manage_stock == 1
      manage_stock = false if manage_stock == 0
      {
        'id' => row.fetch('id').to_s, 'sku' => sku,
        'barcode' => text(effective.call('barcode'), 255),
        'name' => text(row['full_name'] || row['attribute_name'], 1000),
        'quantity' => quantity, 'manage_stock' => manage_stock == true,
        'product_name' => text(row.dig('product', 'name'), 1000),
        'category' => text(row.dig('product', 'category', 'name'), 500),
        'product_id' => row['product_id']&.to_s,
        'website_product_id' => row.dig('product', 'shopify_product_identifier')&.to_s,
        'website_variant_id' => row['shopify_product_variant_identifier']&.to_s,
        'price_cents' => minor_units(effective.call('is_promo_pricing_enabled') == true ? effective.call('promo_price') : effective.call('regular_price')),
        # Cost as entered in C-Trax (same units as its prices); 0 means not entered, kept as unknown.
        'cost_cents' => (cost = minor_units(effective.call('cost'))) && cost.positive? ? cost : nil,
        'tax_status' => effective.call('tax_status'),
        'tax_rates_mbp' => tax_rates(effective.call('tax_status'), row['attribute_store_overrides']),
        'tax_rate_mbp' => tax_rates(effective.call('tax_status'), row['attribute_store_overrides'])&.sum,
        'variable_price' => effective.call('has_variable_pricing') == true,
        'listed' => effective.call('is_listed_for_sale') != false
      }
    rescue KeyError, TypeError
      raise Client::Error, :response
    end

    def text(value, maximum)
      return nil if value.nil?
      raise Client::Error, :response unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= maximum

      value.presence
    end

    def tax_rates(status, overrides)
      return [] if status == 'none'
      return unless status == 'taxable' && overrides.is_a?(Hash)

      rates = overrides['tax_rates']
      return unless rates.is_a?(Array) && rates.all? { |rate| rate.is_a?(Hash) && rate['rate_mbp'].to_s.match?(/\A[0-9]{1,8}\z/) }

      value = rates.sum { |rate| rate['rate_mbp'].to_i }
      rates.map { |rate| rate['rate_mbp'].to_i } if value.between?(0, 10_000_000)
    end

    def minor_units(value)
      value.to_i if value && value.to_s.match?(/\A\d{1,9}\z/)
    end
  end
end
