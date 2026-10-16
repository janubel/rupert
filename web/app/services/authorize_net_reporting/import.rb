# frozen_string_literal: true

require 'bigdecimal'
require 'time'

module AuthorizeNetReporting
  class Import
    TRANSACTION_FIELDS = {
      'refTransId' => :reference_transaction_id, 'transactionType' => :transaction_type,
      'transactionStatus' => :payment_status, 'marketType' => :market_type, 'product' => :product
    }.freeze
    STAT_FIELDS = %w[accountType chargeAmount chargeCount refundAmount refundCount voidCount declineCount errorCount
      returnedItemAmount returnedItemCount chargebackAmount chargebackCount correctionNoticeCount
      chargeChargeBackAmount chargeChargeBackCount refundChargeBackAmount refundChargeBackCount
      chargeReturnedItemsAmount chargeReturnedItemsCount refundReturnedItemsAmount refundReturnedItemsCount].freeze

    def self.call(connection:, from: 7.days.ago, to: Time.current, transaction_id: nil)
      SyncObservability.observe('authorize_net', transaction_id ? 'events' : 'reporting') do
        new(connection).call(from: from, to: to, transaction_id: transaction_id)
      end
    end

    def initialize(connection)
      @connection = connection
      raise Client::Error.new('Reporting connection belongs to another workspace.', reason: :invalid) unless connection.tenant_id == Current.tenant_id && connection.provider == 'authorize_net_reporting'
      @client = Client.new(connection)
    end

    def call(from:, to:, transaction_id: nil)
      merchant = @client.merchant
      gateway_id = merchant.fetch('gatewayId').to_s
      # Details have no currency field. Infer only for a single-currency merchant.
      currencies = merchant['currencies']
      currency = currencies.is_a?(Array) && currencies.size == 1 && currencies.first.to_s.match?(/\A[A-Z]{3}\z/) ? currencies.first : nil
      batches = transaction_id ? [] : @client.batches(from: from, to: to)
      source_batches = {}
      summaries = batches.flat_map do |batch|
        @client.transactions(batch_id: batch.fetch('batchId')).each do |summary|
          source_batches[summary.fetch('transId').to_s] = batch.except('statistics')
        end
      end + (transaction_id ? [{ 'transId' => transaction_id }] : @client.transactions)
      scope = { environment: @connection.environment, gateway_id: gateway_id }
      # Revisit observed unsettled/auth transactions even after they disappear from lists (e.g. voids).
      pending = transaction_id ? [] : AuthorizeNetTransaction.where(**scope).where.not(payment_status: AuthorizeNetTransaction::FINAL_STATUSES).pluck(:source_transaction_id)
      ids = (summaries.map { |row| row.fetch('transId').to_s } + pending).uniq
      raise Client::Error.new('Reporting exceeded the transaction limit. Use a smaller window.', reason: :limit) if ids.size > 20_000
      observed_at = Time.current
      rows = ids.map do |id|
        detail = @client.detail(id)
        # Batch membership from getTransactionList remains provenance even if
        # the optional detail.batch block is absent.
        detail = detail.merge('batch' => source_batches[id]) if detail['batch'].nil? && source_batches[id]
        normalize(detail, currency: currency, observed_at: observed_at)
      end
      normalized_batches = batches.map { |batch| normalize_batch(batch, observed_at: observed_at) }
      # OAuth rotation may have advanced this instance's setup version.
      version = @connection.lock_version
      fresh = PosConnection.find(@connection.id)
      fresh.with_lock do
        raise Client::Error.new('Reporting setup changed during import; retry.', reason: :changed) unless fresh.lock_version == version
        normalized_batches.each do |attrs|
          record = AuthorizeNetBatch.find_or_initialize_by(**scope, source_batch_id: attrs.delete(:source_batch_id))
          record.update!(attrs) unless record.observed_at && record.observed_at > observed_at
        end
        rows.each do |attrs|
          record = AuthorizeNetTransaction.find_or_initialize_by(**scope, source_transaction_id: attrs.delete(:source_transaction_id))
          next if record.observed_at && record.observed_at > observed_at

          history = record.status_history.dup
          if history.last&.fetch('status', nil) != attrs[:payment_status]
            history << { 'status' => attrs[:payment_status], 'observed_at' => observed_at.iso8601 }
          end
          record.update!(attrs.merge(status_history: history))
        end
        fresh.update!(last_reported_at: observed_at, last_report_status: 'complete',
          last_report_message: "Imported #{rows.size} payment observations and #{batches.size} settlement batches.") unless transaction_id
      end
      @connection.reload
      { transactions: rows.size, batches: batches.size }
    rescue KeyError, ArgumentError, TypeError
      raise Client::Error.new('Reporting data did not match the verified contract. No import was completed.', reason: :response)
    end

    private

    def normalize(row, currency:, observed_at:)
      attrs = TRANSACTION_FIELDS.to_h { |source, target| [target, row[source]] }
      raise Client::Error.new('Reporting omitted transaction type or status.', reason: :response) unless attrs[:transaction_type].is_a?(String) && attrs[:transaction_type].present? && attrs[:payment_status].is_a?(String) && attrs[:payment_status].present?
      batch = row['batch'] || {}
      attrs.merge(source_transaction_id: row.fetch('transId').to_s,
        submitted_at: utc_time(row.fetch('submitTimeUTC')), source_batch_id: batch['batchId']&.to_s,
        settled_at: batch['settlementTimeUTC'] && utc_time(batch['settlementTimeUTC']),
        settlement_state: batch['settlementState'], currency: currency, invoice_number: invoice_number(row.dig('order', 'invoiceNumber')),
        authorized_amount: amount(row.fetch('authAmount')), settled_amount: amount(row.fetch('settleAmount')),
        tip_amount: row['tip'] && amount(row['tip'].fetch('amount')),
        surcharge_amount: row['surcharge'] && amount(row['surcharge'].fetch('amount')), observed_at: observed_at)
    end

    def normalize_batch(batch, observed_at:)
      stats = batch['statistics'] || []
      raise Client::Error.new('Reporting returned invalid batch statistics.', reason: :response) unless stats.is_a?(Array) && stats.all? { |s| s.is_a?(Hash) }
      { source_batch_id: batch.fetch('batchId').to_s, settlement_state: batch.fetch('settlementState'),
        settled_at: batch['settlementTimeUTC'] && utc_time(batch['settlementTimeUTC']),
        payment_method: batch['paymentMethod'], statistics: stats.map { |s| s.slice(*STAT_FIELDS).transform_values(&:to_s) }, observed_at: observed_at }
    end

    def invoice_number(value)
      return if value.nil? || value == ''
      raise Client::Error.new('Reporting returned an invalid invoice reference.', reason: :response) unless value.is_a?(String) && value.bytesize <= 100 && value.valid_encoding? && !value.match?(/[\x00-\x1f\x7f]/)

      value
    end

    def utc_time(value)
      text = value.to_s
      # The field is explicitly UTC; some official samples omit the suffix.
      text += 'Z' unless text.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(text).utc
    end

    def amount(value)
      number = BigDecimal(value.to_s)
      raise Client::Error.new('Reporting returned an invalid monetary amount.', reason: :response) unless number.finite? && number >= 0 && number < 10**15 && number == number.round(4)
      number
    end
  end
end
