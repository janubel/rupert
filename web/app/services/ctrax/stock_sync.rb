# frozen_string_literal: true

require 'bigdecimal'

module Ctrax
  class StockSync
    def self.call(connection:)
      new(connection).call
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
        'quantity' => quantity, 'manage_stock' => manage_stock == true
      }
    rescue KeyError, TypeError
      raise Client::Error, :response
    end

    def text(value, maximum)
      return nil if value.nil?
      raise Client::Error, :response unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= maximum

      value.presence
    end
  end
end
