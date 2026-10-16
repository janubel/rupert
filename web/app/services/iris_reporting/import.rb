# frozen_string_literal: true

require 'bigdecimal'

module IrisReporting
  class Import
    REQUIRED = %w[transactions deposits].freeze
    OPTIONAL = %w[chargebacks retrievals statements].freeze
    FIELDS = {
      'transactions' => %w[id date reference_number amount count terminal_number],
      'transaction' => %w[id date type amount pos_entry_mode invoice_number void_reject_chargeback reject_description card_type purchase_id],
      'deposits' => %w[date amount transactions batch],
      'adjustments' => %w[date type amount],
      'chargebacks' => %w[id case_number chargeback_date transaction_date respond_due amount original_amount currency reason reason_code transaction_id reference_number case_status case_status_description last_status_date updated_at],
      'retrievals' => %w[id case_number retrieval_date transaction_date respond_due amount original_amount currency reason reason_code transaction_id reference_number case_status case_status_description last_status_date updated_at],
      'statements' => %w[id date]
    }.freeze

    def self.call(connection:, from: Date.current - 30, to: Date.current)
      SyncObservability.observe('bank', 'reporting') { read(connection: connection, from: from, to: to) }
    end

    def self.read(connection:, from:, to:)
      raise Client::Error, :invalid unless connection.tenant_id == Current.tenant_id && connection.provider == 'iris_reporting' && connection.vendor_approved && connection.credentials_saved? && connection.environment == 'production'

      version = connection.lock_version
      origin = connection.credential_values.fetch('api_url')
      # Each merchant gets its own bounded request budget.
      reports = Client.merchants(connection.account_reference).flat_map do |mid|
        client = Client.new(connection.credential_values)
        (REQUIRED + OPTIONAL).map do |kind|
          begin
            raw = client.report(kind, merchant: mid, from: from, to: to)
            payload = sanitize(kind, raw)
            status = 'complete'
          rescue Client::Error => e
            raise unless OPTIONAL.include?(kind) && (%i[forbidden unavailable].include?(e.reason) || (kind == 'statements' && e.reason == :response))

            payload = { 'message' => e.message }
            status = 'unavailable'
          end
          { api_origin: origin, merchant_number: mid, report_kind: kind,
            window_from: from, window_to: to, status: status, payload_json: payload.to_json, observed_at: Time.current }
        end
      end
      fresh = PosConnection.find(connection.id)
      fresh.with_lock do
        raise Client::Error, :stale unless fresh.lock_version == version

        reports.each do |attrs|
          identity = attrs.slice(:api_origin, :merchant_number, :report_kind, :window_from, :window_to)
          record = IrisReport.find_or_initialize_by(identity)
          if attrs[:status] == 'unavailable' && record.persisted?
            attrs[:payload_json] = record.payload.merge('read_warning' => JSON.parse(attrs[:payload_json]).fetch('message'),
              'previous_observed_at' => record.observed_at.iso8601).to_json
          end
          record.update!(attrs)
        end
        unavailable = reports.count { |report| report[:status] == 'unavailable' }
        fresh.update!(last_reported_at: Time.current, last_report_status: unavailable.positive? ? 'partial' : 'complete',
          last_report_message: "Saved #{reports.size - unavailable} IRIS reports; #{unavailable} optional reports unavailable.")
      end
      connection.reload
      { reports: reports.size }
    end

    def self.sanitize(kind, document)
      if kind == 'deposits'
        # Totals are not stored as duplicate sales. Preserve row-level
        # adjustments separately; amounts are signed source observations.
        return %w[deposits adjustments].to_h { |key| [key, document.fetch(key).map { |row| clean(key, row) }] }
      end
      { 'data' => document.fetch('data').map do |row|
        clean(kind, row).tap do |safe|
          next unless kind == 'transactions'

          children = row['transactions']
          raise Client::Error, :response unless children.is_a?(Array) && children.size <= Client::MAX_ROWS && children.all? { |child| child.is_a?(Hash) }

          ids = children.map { |child| child['id'].to_s }
          raise Client::Error, :response unless ids.uniq.size == ids.size && ids.all? { |id| id.match?(/\A[0-9]{1,30}\z/) }

          safe['transactions'] = children.map { |child| clean('transaction', child) }
        end
      end }
    rescue KeyError, TypeError, ArgumentError
      raise Client::Error, :response
    end

    def self.clean(kind, row)
      safe = row.slice(*FIELDS.fetch(kind))
      raise Client::Error, :response unless safe.values.all? { |value| value.nil? || value == true || value == false || value.is_a?(Numeric) || (value.is_a?(String) && value.bytesize <= 1000) }

      %w[amount original_amount].each do |key|
        next unless safe.key?(key) && !safe[key].nil?

        value = BigDecimal(safe[key].to_s)
        raise Client::Error, :response unless value.finite? && value.abs < 10**15 && value == value.round(4)

        safe[key] = value.to_s('F')
      end
      safe
    rescue ArgumentError
      raise Client::Error, :response
    end
  end
end
