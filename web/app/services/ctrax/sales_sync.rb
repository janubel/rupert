# frozen_string_literal: true

require 'digest'

module Ctrax
  class SalesSync
    ORDER_MONEY = %w[total subtotal tax discount tip shipping_amount shipping_tax_amount].freeze
    PAYMENT_MONEY = %w[amount total_amount tip_amount surcharge_amount tendered_amount change_back_amount].freeze
    CONTROL_FIELDS = %w[order_count orders_totals_sum orders_subtotals_sum orders_taxes_sum orders_discounts_sum
                        orders_tips_sum refund_count refunds_totals_sum refunds_taxes_sum refunds_tips_sum
                        cash_payments_amount_sum credit_payments_amount_sum standaloneCardTerminal_payments_amount_sum
                        loyalty_payments_amount_sum gift_card_payments_amount_sum cash_refunds_amount_sum].freeze

    def self.call(connection:, date:, currency: 'USD')
      new(connection, date, currency).call
    end

    def initialize(connection, date, currency)
      @connection = connection
      @date = Date.iso8601(date.to_s)
      @currency = currency
      raise Client::Error, :invalid unless @date.year.between?(2020, 2100) && currency.match?(/\A[A-Z]{3}\z/)
    rescue Date::Error
      raise Client::Error, :invalid
    end

    def call
      raise Client::Error, :invalid unless @connection.persisted? && @connection.provider == 'ctrax' &&
                                           @connection.tenant_id == Current.tenant_id && @connection.vendor_approved &&
                                           @connection.credentials_saved?

      version = @connection.lock_version
      started = Time.current
      client = Client.new(@connection.credential_values)
      snapshots = client.stores.map do |store|
        timezone = client.use_store(store[:id])
        @zone = Time.find_zone!(timezone)
        @from = @zone.local(@date.year, @date.month, @date.day)
        @to = @from.advance(days: 1)
        orders = client.daily_orders(store[:id], @date).filter_map { |row| normalize_order(row, store[:id]) }
        sessions = client.register_sessions(store[:id], @date).filter_map do |row|
          opened = timestamp(row['opened_at'])
          closed = timestamp(row['closed_at'], optional: true)
          next if opened >= @to || (closed && closed <= @from) || row['deleted_at'].present?

          drops = client.cash_drops(row.fetch('id')).map do |drop|
            { 'id' => identity(drop['id']), 'amount' => money(drop['amount']),
              'created_at' => timestamp(drop['created_at'], optional: true)&.iso8601 }
          end
          { 'id' => identity(row['id']), 'register_id' => identity(row['register_id']),
            'register_name' => text(row['register_name']), 'opened_at' => opened.iso8601,
            'closed_at' => closed&.iso8601, 'opening_cash' => money(row['opening_cash']),
            'closing_cash' => money(row['closing_cash']), 'cash_drops' => drops }
        end
        report = client.sales_summary(store[:id], @date)
        raise Client::Error, :response unless report['rows'].is_a?(Array) && report['rows'].all? { |row| row.is_a?(Hash) }

        controls = CONTROL_FIELDS.to_h do |key|
          values = report['rows'].map { |row| money(row[key]) }
          [key, values.empty? || values.any?(&:nil?) ? nil : values.sum]
        end
        # Ordering does not create a new review version; changed source facts do.
        orders.sort_by! { |row| row['id'].to_i }
        sessions.sort_by! { |row| row['id'].to_i }
        payload = { orders_json: orders, sessions_json: sessions, controls_json: controls,
                    timezone: timezone, currency: @currency }
        store.merge(payload: payload, digest: Digest::SHA256.hexdigest(JSON.generate(payload)))
      end
      @connection.with_lock do
        raise Client::Error, :response unless @connection.lock_version == version

        snapshots.each do |store|
          origin = @connection.credential_values.fetch('api_url')
          location = Location.find_or_initialize_by(source: 'ctrax', externalId: "#{URI(origin).host}/#{store[:id]}")
          location.update!(name: store[:name], active: true)
          day = CtraxDay.find_or_initialize_by(location_id: location.id, business_date: @date)
          raise Client::Error, :response if day.captured_at && day.captured_at > started

          day.update!(store[:payload].merge(api_origin: origin, store_id: store[:id],
            source_digest: store[:digest], captured_at: started))
        end
        @connection.update!(last_report_status: 'verified', last_reported_at: Time.current,
          last_report_message: "C-Trax daily read completed for #{@date}: #{snapshots.sum { |s| s[:payload][:orders_json].size }} orders.")
      end
      { stores: snapshots.size, orders: snapshots.sum { |s| s[:payload][:orders_json].size }, date: @date.iso8601 }
    rescue KeyError, TypeError, ArgumentError
      raise Client::Error, :response
    end

    private

    def normalize_order(row, store_id)
      raise Client::Error, :response unless identity(row['store_id']) == store_id && row['payments'].is_a?(Array) &&
                                            row['line_items'].is_a?(Array) && row['refunds'].is_a?(Array)

      completed = timestamp(row['completed_at'], optional: true)
      return unless completed && completed >= @from && completed < @to

      payments = row['payments'].map do |payment|
        raise Client::Error, :response unless identity(payment['order_id']) == identity(row['id'])

        { 'id' => identity(payment['id']), 'type' => text(payment['type']), 'status' => text(payment['status']),
          'deleted' => payment['deleted_at'].present? }.merge(PAYMENT_MONEY.to_h { |key| [key, money(payment[key])] })
      end
      lines = row['line_items'].map do |line|
        { 'id' => identity(line['id']), 'variant_id' => identity(line['product_variant_id']),
          'name' => text(line['product_name']), 'variant_name' => text(line['product_variant_name']),
          'price' => money(line['price']), 'tax' => money(line['tax_amount']) }
      end
      raise Client::Error, :response unless [payments, lines].all? { |rows| rows.pluck('id').uniq.size == rows.size }

      { 'id' => identity(row['id']), 'receipt' => text(row['register_transaction_identifier'].to_s),
        'register_session_id' => identity(row['register_session_id']), 'status' => text(row['status']),
        'completed_at' => completed.iso8601, 'updated_at' => timestamp(row['updated_at']).iso8601,
        'deleted' => row['deleted_at'].present?, 'payments' => payments, 'lines' => lines,
        'refund_count' => row['refunds'].size }.merge(ORDER_MONEY.to_h { |key| [key, money(row[key])] })
    end

    def identity(value)
      value = value.to_s
      raise Client::Error, :response unless value.match?(/\A[1-9][0-9]{0,18}\z/)

      value
    end

    def money(value)
      return if value.nil?
      raise Client::Error, :response unless value.to_s.match?(/\A-?[0-9]{1,12}\z/)

      value.to_i
    end

    def text(value)
      return if value.nil?
      raise Client::Error, :response unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 1000

      value
    end

    def timestamp(value, optional: false)
      return if optional && value.blank?
      raise Client::Error, :response unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/)

      Time.iso8601(value)
    rescue ArgumentError
      Time.find_zone!('UTC').strptime(value, '%Y-%m-%d %H:%M:%S')
    end
  end
end
