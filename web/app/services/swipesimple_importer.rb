# frozen_string_literal: true

require 'bigdecimal'
require 'csv'
require 'date'
require 'digest'
require 'json'
require 'set'
require 'time'

# Imports Rupert's supported completed-sale line-item CSV, not every native
# SwipeSimple export. Parsing/preview is read-only. Local imports are atomic;
# exact replays do nothing and changed identities require a correction workflow.
class SwipesimpleImporter
  MAX_BYTES = 2 * 1024 * 1024
  MAX_ROWS = 5000
  MAX_COLUMNS = 32
  MAX_CENTS = 2_147_483_647
  MAX_QUANTITY = 1_000_000
  SUPPORTED_CURRENCIES = %w[USD CAD EUR GBP AUD NZD].freeze
  MAX_FIELD_BYTES = 1024
  Error = Class.new(ArgumentError)
  Result = Struct.new(:orders, :lines, :payments, :skipped_rows, :unchanged_orders, keyword_init: true)

  COLUMN_ALIASES = {
    order_id: %w[orderid order id invoice invoiceid receipt receiptid transactionid transaction transactionnumber],
    order_number: %w[ordernumber ordernum receiptnumber invoicenumber],
    date: %w[date datetime date_time saledate transactiondate paidat createdat created time],
    item: %w[item itemname product productname name description itemdescription title],
    sku: %w[sku itemsku productsku upc itemcode code],
    quantity: %w[quantity qty count qtysold units],
    unit_price: %w[unitprice price unitcost unitamount amounteach saleprice],
    line_total: %w[total amount linetotal linetotalamount gross linamount],
    order_total: %w[ordertotal grandtotal totalamount receipttotal],
    payment: %w[payment paymentmethod method tender tendertype cardbrand paymenttype],
    customer: %w[customer customername name firstname lastname],
    status: %w[status salestatus result],
    currency: %w[currency currencycode],
    type: %w[type transactiontype saletype],
    location: %w[location locationid store storeid merchantaccount merchantaccountid]
  }.freeze
  REQUIRED_COLUMNS = %i[order_id date item quantity unit_price payment status currency].freeze
  TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\z/
  WARNINGS = [
    'Only completed sales in this supported line-item CSV are imported; refunds, voids, failed payments and authorizations are unsupported.',
    'Tax, collected tips, discounts, merchant fees, settlements and bank deposits are unavailable in this import.',
    'Timestamps must include a UTC offset. Source checkout times and item prices still require operator verification.',
    'This import changes only Rupert records; it does not change stock or contact a merchant provider.'
  ].freeze

  class Preview
    attr_reader :records, :fingerprint

    def initialize(records:, fingerprint:, skipped_rows:, warnings:)
      @records = records.freeze
      @fingerprint = fingerprint.freeze
      @summary = {
        orders: records.length, lines: records.sum { |record| record[:lines].length },
        payments: records.length, skipped_rows: skipped_rows,
        gross_cents: records.sum { |record| record[:gross_cents] }, currency: records.first.fetch(:currency),
        warnings: warnings.freeze
      }.freeze
      freeze
    end

    def summary
      @summary
    end

    def to_h
      summary
    end
  end

  class << self
    def preview(source)
      text = read_source(source)
      fingerprint = Digest::SHA256.hexdigest(text.b)
      reader = CSV.new(text.delete_prefix("\uFEFF"), headers: true, field_size_limit: MAX_FIELD_BYTES)
      table = []
      reader.each do |row|
        raise Error, "The CSV exceeds the #{MAX_ROWS}-row limit." if table.length >= MAX_ROWS

        table << row
      end
      physical_headers = reader.headers
      unless physical_headers.is_a?(Array) && physical_headers.present?
        raise Error, 'The CSV must contain headers and completed-sale rows.'
      end

      raise Error, 'The CSV exceeds the 32-column limit.' if physical_headers.length > MAX_COLUMNS

      headers = map_headers(physical_headers)
      parsed = []
      skipped_rows = 0
      table.each_with_index do |row, index|
        if row.fields.all?(&:blank?)
          skipped_rows += 1
          next
        end
        fail_row!(index + 2, 'The number of cells does not match the header') unless row.fields.length == physical_headers.length
        parsed << parse_row(row.fields, headers, index + 2)
      end
      raise Error, 'The CSV contains no completed-sale rows.' if parsed.empty?
      raise Error, 'Import one currency per file; currencies cannot be combined.' unless parsed.pluck(:currency).uniq.one?

      records = parsed.group_by { |row| row[:order_id] }.map { |id, rows| prepare_order(id, rows) }
        .sort_by { |record| record[:source_order_id] }
      warnings = WARNINGS.dup
      warnings << 'Customer identities are not imported: customer names alone cannot identify a CRM customer.' if headers.key?(:customer)
      Preview.new(records: records, fingerprint: fingerprint, skipped_rows: skipped_rows, warnings: warnings)
    rescue CSV::MalformedCSVError
      raise Error, 'The CSV could not be parsed. Check quoting, columns and field lengths.', cause: nil
    end

    def import!(source, expected_fingerprint: nil)
      prepared = preview(source)
      if expected_fingerprint && prepared.fingerprint != expected_fingerprint
        raise Error, 'The CSV changed after preview. Preview the current file before importing.'
      end
      tenant_id = Current.tenant_id
      raise Error, 'An active workspace is required for this import.' if tenant_id.blank?

      unchanged = 0
      result = nil
      Core::Order.transaction do
        # Acquire the writer/tenant row lock before replay reads, avoiding SQLite
        # deferred read-to-write upgrades and serializing same-tenant imports.
        locked = Tenant.unscoped.where(id: tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
        raise Error, 'The import workspace could not be found.' unless locked == 1

        existing, ledgers, refunded, legacy_ids = existing_records(prepared.records, tenant_id)
        prepared.records.each do |record|
          if legacy_ids.include?(record[:source_order_id])
            raise Error, 'A legacy ledger identity already exists. Nothing was imported; review the existing records separately.'
          end
          order = existing[record[:source_order_id]]
          ledger = ledgers[ledger_id(tenant_id, record[:source_order_id])]
          if order
            unless !refunded.include?(order.id) && unchanged_order?(order, record) && unchanged_ledger?(ledger, record)
              raise Error, 'An existing transaction differs or has refund history. Nothing was imported; review a correction separately.'
            end
            unchanged += 1
          elsif ledger
            raise Error, 'An existing ledger identity has no matching order. Nothing was imported; review it separately.'
          end
        end
        created = prepared.records.reject { |record| existing.key?(record[:source_order_id]) }
        created.each { |record| create_order!(record, tenant_id) }
        result = Result.new(orders: created.length, lines: created.sum { |record| record[:lines].length },
          payments: created.length, skipped_rows: prepared.summary[:skipped_rows], unchanged_orders: unchanged)
        begin
          yield result if block_given?
        rescue ActiveRecord::Rollback
          raise Error, 'The import transaction was cancelled. Nothing was imported.'
        end
      end
      result
    rescue ActiveRecord::ActiveRecordError
      raise Error, 'The local records could not be imported safely. Nothing was imported; review the file and existing transactions.', cause: nil
    end

    private

    def read_source(source)
      text = if source.is_a?(String)
        source.dup
      elsif source.respond_to?(:read)
        source.read(MAX_BYTES + 1).to_s
      else
        raise Error, 'Provide CSV text or a readable CSV file.'
      end
      raise Error, 'The CSV exceeds the 2 MiB file limit.' if text.bytesize > MAX_BYTES

      text = text.b.force_encoding(Encoding::UTF_8)
      raise Error, 'The CSV must be valid UTF-8 text without null characters.' unless text.valid_encoding? && !text.include?("\x00")

      text
    end

    def map_headers(physical_headers)
      mapping = {}
      physical_headers.each_with_index do |header, index|
        normalized = header.to_s.downcase.gsub(/[^a-z0-9]/, '')
        matches = COLUMN_ALIASES.select do |_key, aliases|
          aliases.map { |value| value.gsub(/[^a-z0-9]/, '') }.include?(normalized)
        end.keys
        raise Error, "Column #{index + 1} is unsupported or ambiguous. Use the documented line-item CSV headers." unless matches.one?
        raise Error, "Column #{index + 1} duplicates another field. Use one header per field." if mapping.key?(matches.first)

        mapping[matches.first] = index
      end
      unless REQUIRED_COLUMNS.all? { |key| mapping.key?(key) }
        raise Error, 'Required columns: Order, Date, Item, Qty, Unit Price, Payment, Status and Currency.'
      end
      mapping
    end

    def parse_row(fields, headers, row_number)
      cells = fields.map { |value| value.to_s.strip }
      if cells.any? { |value| value.bytesize > MAX_FIELD_BYTES || value.match?(/[\x00-\x1f\x7f]/) }
        fail_row!(row_number, 'A cell is too long or contains unsupported control characters')
      end
      get = ->(key) { headers.key?(key) ? cells[headers[key]] : '' }
      id = text_field!(get.call(:order_id), row_number, 'A stable order or transaction ID is required', maximum: 128)
      item = text_field!(get.call(:item), row_number, 'An item name is required', maximum: 255)
      sku = text_field!(get.call(:sku), row_number, 'The SKU is too long', maximum: 128, optional: true)
      order_number = text_field!(get.call(:order_number), row_number, 'The order number is too long', maximum: 128, optional: true)
      unless %w[approved completed paid].include?(get.call(:status).downcase)
        fail_row!(row_number, 'Only explicitly approved, completed or paid sale rows are supported')
      end
      if headers.key?(:type) && get.call(:type).downcase != 'sale'
        fail_row!(row_number, 'Only sale transactions are supported; refunds, voids and authorizations require another workflow')
      end
      fail_row!(row_number, 'Location mappings are not supported by this CSV contract') if get.call(:location).present?
      currency = get.call(:currency)
      unless SUPPORTED_CURRENCIES.include?(currency)
        fail_row!(row_number, 'Currency must be an explicit supported two-decimal currency code')
      end
      quantity_text = get.call(:quantity)
      unless quantity_text.match?(/\A[1-9][0-9]{0,6}\z/) && quantity_text.to_i <= MAX_QUANTITY
        fail_row!(row_number, 'Quantity must be a positive whole number within the supported limit')
      end
      quantity = quantity_text.to_i
      unit = cents!(get.call(:unit_price), currency, row_number)
      line = unit * quantity
      fail_row!(row_number, 'The line amount exceeds the supported limit') if line > MAX_CENTS
      if get.call(:line_total).present? && cents!(get.call(:line_total), currency, row_number) != line
        fail_row!(row_number, 'Line total must equal quantity times unit price; adjustments require another format')
      end
      {
        row_number: row_number, order_id: id, order_number: order_number, occurred_at: timestamp!(get.call(:date), row_number),
        currency: currency, method: method!(get.call(:payment), row_number),
        order_total: get.call(:order_total).present? ? cents!(get.call(:order_total), currency, row_number) : nil,
        line: { sku: sku.presence, name: item, quantity: quantity, unit_cents: unit, line_cents: line }.freeze
      }
    end

    def text_field!(value, row, reason, maximum:, optional: false)
      fail_row!(row, reason) if value.bytesize > maximum || (!optional && value.blank?)
      value.freeze
    end

    def cents!(value, currency, row)
      pattern = /\A\$?(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?\z/
      unless value.match?(pattern) && !(value.start_with?('$') && currency != 'USD')
        fail_row!(row, 'Money must be a nonnegative decimal with at most two decimal places')
      end
      cents = (BigDecimal(value.delete('$,')) * 100).to_i
      fail_row!(row, 'The money amount exceeds the supported limit') if cents > MAX_CENTS
      cents
    end

    def timestamp!(value, row)
      unless TIMESTAMP_PATTERN.match?(value) && !value.end_with?('-00:00')
        fail_row!(row, 'Date must be an ISO8601 timestamp with seconds and an explicit UTC offset')
      end
      date = DateTime.iso8601(value)
      fail_row!(row, 'The timestamp offset is unsupported') if date.offset.abs > Rational(14, 24)
      Time.iso8601(value).utc.freeze
    rescue ArgumentError
      fail_row!(row, 'Date must be a valid ISO8601 timestamp with seconds and an explicit UTC offset')
    end

    def method!(value, row)
      normalized = value.downcase.gsub(/[ _-]/, '')
      method = case normalized
      when 'card', 'creditcard', 'debitcard', 'visa', 'mastercard', 'amex', 'americanexpress', 'discover' then 'card'
      when 'cash' then 'cash'
      when 'gift', 'giftcard' then 'gift_card'
      when 'check', 'cheque' then 'check'
      when 'other' then 'other'
      end
      fail_row!(row, 'Payment must be an explicit supported tender; unknown or split tenders cannot be inferred') unless method
      method.freeze
    end

    def prepare_order(id, rows)
      first = rows.first
      [:occurred_at, :currency, :method].each do |key|
        fail_row!(first[:row_number], 'Rows sharing an order ID have conflicting order details or tenders') unless rows.pluck(key).uniq.one?
      end
      numbers = rows.pluck(:order_number).filter_map(&:presence).uniq
      fail_row!(first[:row_number], 'Rows sharing an order ID have conflicting order numbers') if numbers.length > 1
      lines = rows.pluck(:line).sort_by { |line| JSON.generate(line) }
      fail_row!(first[:row_number], 'Duplicate item rows are ambiguous; combine quantities in one row') unless lines.uniq.length == lines.length
      if lines.sum { |line| line[:quantity] } > MAX_CENTS
        fail_row!(first[:row_number], 'The aggregate order quantity exceeds the supported limit')
      end
      gross = lines.sum { |line| line[:line_cents] }
      fail_row!(first[:row_number], 'An order must have a positive total within the supported limit') unless gross.between?(1, MAX_CENTS)
      if rows.any? { |row| row[:order_total] && row[:order_total] != gross }
        fail_row!(first[:row_number], 'Order totals must equal the sum of supported item lines')
      end
      {
        source_order_id: id, order_number: numbers.first || "SS-#{id}".freeze,
        occurred_at: first[:occurred_at], currency: first[:currency].freeze,
        gross_cents: gross, method: first[:method], lines: lines.freeze
      }.freeze
    end

    def existing_records(records, tenant_id)
      existing = {}
      ledgers = {}
      refunded = Set.new
      legacy_ids = Set.new
      records.each_slice(500) do |batch|
        orders = Core::Order.where(tenant_id: tenant_id, source: 'swipesimple', source_order_id: batch.pluck(:source_order_id))
          .includes(:order_lines, :payments).to_a
        existing.merge!(orders.index_by(&:source_order_id))
        refunded.merge(Core::Refund.unscoped.where(tenant_id: tenant_id, order_id: orders.map(&:id)).pluck(:order_id))
        batch_ledgers = LedgerEntry.where(tenant_id: tenant_id, source: 'swipesimple', sourceOrderId: batch.pluck(:source_order_id)).to_a
        ledgers.merge!(batch_ledgers.index_by(&:id))
        batch_ledgers.each do |ledger|
          legacy_ids << ledger.sourceOrderId if ledger.id != ledger_id(tenant_id, ledger.sourceOrderId)
        end
      end
      [existing, ledgers, refunded, legacy_ids]
    end

    def unchanged_order?(order, record)
      order.status == 'paid' && order.channel == 'pos' && order.location_id.nil? && order.tax_cents.nil? &&
        order.order_number == record[:order_number] && order.currency == record[:currency] &&
        order.gross_cents == record[:gross_cents] && order.line_items == record[:lines].length &&
        same_time?(order.occurred_at, record[:occurred_at]) &&
        order.order_lines.map { |line| line.attributes.symbolize_keys.slice(:sku, :name, :quantity, :unit_cents, :line_cents) }
          .sort_by { |line| JSON.generate(line) } == record[:lines] &&
        unchanged_payments?(order, record)
    end

    def unchanged_payments?(order, record)
      payments = order.payments.to_a
      payments.one? && payments.first.method == record[:method] && payments.first.status == 'completed' &&
        payments.first.reference == record[:source_order_id] && payments.first.amount_cents == record[:gross_cents] &&
        same_time?(payments.first.paid_at, record[:occurred_at])
    end

    def unchanged_ledger?(ledger, record)
      ledger && ledger.source == 'swipesimple' && ledger.sourceOrderId == record[:source_order_id] &&
        ledger.orderName == record[:order_number] && ledger.currency == record[:currency] &&
        ledger.grossCents == record[:gross_cents] && ledger.status == 'COMPLETED' &&
        ledger.lineItems == record[:lines].sum { |line| line[:quantity] } &&
        ledger.summary == record[:lines].first(3).pluck(:name).join(', ') && same_time?(ledger.occurredAt, record[:occurred_at])
    end

    def same_time?(left, right)
      left&.utc&.iso8601(6) == right.utc.iso8601(6)
    end

    def ledger_id(tenant_id, source_order_id)
      "swipesimple:#{Digest::SHA256.hexdigest(JSON.generate([tenant_id, source_order_id]))}"
    end

    def create_order!(record, tenant_id)
      order = Core::Order.create!(
        tenant_id: tenant_id, source: 'swipesimple', source_order_id: record[:source_order_id],
        order_number: record[:order_number], channel: 'pos', occurred_at: record[:occurred_at],
        currency: record[:currency], gross_cents: record[:gross_cents], tax_cents: nil, line_items: record[:lines].length
      )
      record[:lines].each { |line| order.order_lines.create!(line.merge(tenant_id: tenant_id)) }
      order.payments.create!(tenant_id: tenant_id, method: record[:method], amount_cents: record[:gross_cents],
        status: 'completed', reference: record[:source_order_id], paid_at: record[:occurred_at])
      order.mark_paid!
      LedgerEntry.create!(tenant_id: tenant_id, id: ledger_id(tenant_id, record[:source_order_id]), source: 'swipesimple',
        sourceOrderId: record[:source_order_id], orderName: record[:order_number], occurredAt: record[:occurred_at],
        syncedAt: Time.current, currency: record[:currency], grossCents: record[:gross_cents], status: 'COMPLETED',
        lineItems: record[:lines].sum { |line| line[:quantity] }, summary: record[:lines].first(3).pluck(:name).join(', '))
    end

    def fail_row!(row, reason)
      raise Error, "Row #{row}: #{reason}."
    end
  end
end
