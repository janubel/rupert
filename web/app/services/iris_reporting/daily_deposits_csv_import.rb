# frozen_string_literal: true

require 'csv'
require 'digest'
require 'bigdecimal'

module IrisReporting
  # Native batch summaries, never individual sales or proof of net ACH funding.
  class DailyDepositsCsvImport
    MAX_BYTES = 1024 * 1024
    MAX_ROWS = 10_000
    HEADER = ['Date', 'Amount', 'Transactions', 'Batch', 'Terminal Number', 'Type'].freeze

    def self.call(text:, merchant:, period:, origin: 'https://nabankco.iriscrm.com')
      raise Client::Error, :invalid unless Current.tenant&.status == 'active' && Client.merchants(merchant) == [merchant] && Client::ORIGIN_PATTERN.match?(origin)
      payload = parse(text: text, period: period)
      month = Date.iso8601("#{period}-01")
      IrisReport.transaction do
        report = IrisReport.find_or_initialize_by(api_origin: origin, merchant_number: merchant, report_kind: 'daily_deposits_csv',
          window_from: month, window_to: month.end_of_month)
        report.update!(status: 'complete', payload_json: payload.to_json, source_digest: Digest::SHA256.hexdigest(text), observed_at: Time.current)
        report
      end
    end

    def self.parse(text:, period:)
      raise Client::Error, :response unless text.is_a?(String) && text.valid_encoding? && text.bytesize.between?(1, MAX_BYTES)
      raise Client::Error, :response unless period.to_s.match?(/\A20[0-9]{2}-(?:0[1-9]|1[0-2])\z/)

      month = Date.iso8601("#{period}-01")
      csv = CSV.parse(text.delete_prefix("\uFEFF"), field_size_limit: 4096).reject { |row| row.all?(&:blank?) }
      raise Client::Error, :response unless csv.size.between?(4, MAX_ROWS + 4) && csv.shift == ['Daily Deposits']

      preamble = csv.shift
      raise Client::Error, :response unless preamble.size == 1 && preamble.first.to_s.match?(/\ARecords exported: (?:0|[1-9][0-9]{0,4})\z/)

      expected = preamble.first.delete_prefix('Records exported: ').to_i
      raise Client::Error, :response unless expected <= MAX_ROWS && csv.shift == HEADER

      total = csv.pop
      raise Client::Error, :response unless total.size.between?(4, HEADER.size) && total[0] == 'Monthly Total' && total.drop(3).all?(&:blank?) && csv.size == expected

      rows = csv.map do |row|
        raise Client::Error, :response unless row.size == HEADER.size && row.compact.all? { |v| v.bytesize <= 100 && !v.match?(/[\x00-\x1f\x7f]/) }
        raise Client::Error, :response unless row[0].to_s.match?(/\A[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{4}\z/)

        m, d, y = row[0].split('/').map(&:to_i)
        date = Date.new(y, m, d)
        raise Client::Error, :response unless date.beginning_of_month == month

        { 'date' => date.iso8601, 'amount' => amount(row[1]).to_s('F'), 'transactions' => count(row[2]),
          'batch' => reference(row[3]), 'terminal_number' => row[4].present? ? reference(row[4]) : nil, 'type' => reference(row[5]) }
      end
      sum = rows.sum(BigDecimal('0')) { |row| BigDecimal(row.fetch('amount')) }
      transactions = rows.sum { |row| row.fetch('transactions') }
      raise Client::Error, :response unless rows.uniq.size == rows.size && sum == amount(total[1]) && transactions == count(total[2])

      payload = { 'source' => 'native_daily_deposits_csv', 'coverage' => 'export_records_only', 'currency' => nil,
        'data' => rows, 'totals' => { 'amount' => sum.to_s('F'), 'transactions' => transactions, 'records' => expected } }
      payload
    rescue CSV::MalformedCSVError, ArgumentError, TypeError, EncodingError
      raise Client::Error, :response
    end

    def self.amount(value)
      raw = value.to_s
      raw = "-#{raw[1...-1]}" if raw.start_with?('(') && raw.end_with?(')')
      raise Client::Error, :response unless raw.match?(/\A-?\$?(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?\z/)

      number = BigDecimal(raw.delete('$,'))
      raise Client::Error, :response unless number.abs < 10**15

      number
    end

    def self.count(value)
      raise Client::Error, :response unless value.to_s.match?(/\A(?:0|[1-9][0-9]{0,9})\z/)

      value.to_i
    end

    def self.reference(value)
      raise Client::Error, :response unless value.to_s.match?(%r{\A[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,99}\z})

      value
    end
  end
end
