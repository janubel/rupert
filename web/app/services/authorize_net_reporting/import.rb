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

    def self.call(connection:, from: 7.days.ago, to: Time.current)
      new(connection).call(from: from, to: to)
    end

    def initialize(connection)
      @connection = connection
      raise Client::Error, 'Reporting connection belongs to another workspace.' unless connection.tenant_id == Current.tenant_id && connection.provider == 'authorize_net_reporting'
      @client = Client.new(connection)
    end

    def call(from:, to:)
      merchant = @client.merchant
      gateway_id = merchant.fetch('gatewayId').to_s
      # Details have no currency field. Infer only for a single-currency merchant.
      currencies = merchant['currencies']
      currency = currencies.is_a?(Array) && currencies.size == 1 && currencies.first.to_s.match?(/\A[A-Z]{3}\z/) ? currencies.first : nil
      batches = @client.batches(from: from, to: to)
      source_batches = {}
      summaries = batches.flat_map do |batch|
        @client.transactions(batch_id: batch.fetch('batchId')).each do |summary|
          source_batches[summary.fetch('transId').to_s] = batch.except('statistics')
        end
      end + @client.transactions
      scope = { environment: @connection.environment, gateway_id: gateway_id }
      # Revisit observed unsettled/auth transactions even after they disappear from lists (e.g. voids).
      pending = AuthorizeNetTransaction.where(**scope).where.not(payment_status: AuthorizeNetTransaction::FINAL_STATUSES).pluck(:source_transaction_id)
      ids = (summaries.map { |row| row.fetch('transId').to_s } + pending).uniq
      raise Client::Error, 'Reporting exceeded the transaction limit. Use a smaller window.' if ids.size > 20_000
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
        raise Client::Error, 'Reporting setup changed during import; retry.' unless fresh.lock_version == version
        normalized_batches.each do |attrs|
          record = AuthorizeNetBatch.find_or_initialize_by(**scope, source_batch_id: attrs.delete(:source_batch_id))
          record.update!(attrs)
        end
        rows.each do |attrs|
          record = AuthorizeNetTransaction.find_or_initialize_by(**scope, source_transaction_id: attrs.delete(:source_transaction_id))
          history = record.status_history.dup
          if history.last&.fetch('status', nil) != attrs[:payment_status]
            history << { 'status' => attrs[:payment_status], 'observed_at' => observed_at.iso8601 }
          end
          record.update!(attrs.merge(status_history: history))
        end
        fresh.update!(last_reported_at: observed_at, last_report_status: 'complete',
          last_report_message: "Imported #{rows.size} payment observations and #{batches.size} settlement batches.")
      end
      @connection.reload
      { transactions: rows.size, batches: batches.size }
    rescue KeyError, ArgumentError, TypeError
      raise Client::Error, 'Reporting data did not match the verified contract. No import was completed.'
    end

    private

    def normalize(row, currency:, observed_at:)
      attrs = TRANSACTION_FIELDS.to_h { |source, target| [target, row[source]] }
      raise Client::Error, 'Reporting omitted transaction type or status.' unless attrs[:transaction_type].is_a?(String) && attrs[:transaction_type].present? && attrs[:payment_status].is_a?(String) && attrs[:payment_status].present?
      batch = row['batch'] || {}
      attrs.merge(source_transaction_id: row.fetch('transId').to_s,
        submitted_at: utc_time(row.fetch('submitTimeUTC')), source_batch_id: batch['batchId']&.to_s,
        settled_at: batch['settlementTimeUTC'] && utc_time(batch['settlementTimeUTC']),
        settlement_state: batch['settlementState'], currency: currency,
        authorized_amount: amount(row.fetch('authAmount')), settled_amount: amount(row.fetch('settleAmount')),
        tip_amount: row['tip'] && amount(row['tip'].fetch('amount')),
        surcharge_amount: row['surcharge'] && amount(row['surcharge'].fetch('amount')), observed_at: observed_at)
    end

    def normalize_batch(batch, observed_at:)
      stats = batch['statistics'] || []
      raise Client::Error, 'Reporting returned invalid batch statistics.' unless stats.is_a?(Array) && stats.all? { |s| s.is_a?(Hash) }
      { source_batch_id: batch.fetch('batchId').to_s, settlement_state: batch.fetch('settlementState'),
        settled_at: batch['settlementTimeUTC'] && utc_time(batch['settlementTimeUTC']),
        payment_method: batch['paymentMethod'], statistics: stats.map { |s| s.slice(*STAT_FIELDS).transform_values(&:to_s) }, observed_at: observed_at }
    end

    def utc_time(value)
      text = value.to_s
      # The field is explicitly UTC; some official samples omit the suffix.
      text += 'Z' unless text.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(text).utc
    end

    def amount(value)
      number = BigDecimal(value.to_s)
      raise Client::Error, 'Reporting returned an invalid monetary amount.' unless number.finite? && number >= 0 && number < 10**15 && number == number.round(4)
      number
    end
  end
end
