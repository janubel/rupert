# frozen_string_literal: true

require 'csv'
require 'digest'
require 'bigdecimal'

module IrisReporting
  # Monthly summaries have their own report kinds; they never create sales.
  # Accept the documented long-form template or an English table matrix.
  class CsvImport
    METRICS = {
      'sales_health_csv' => { 'Gross Sales' => 'gross_sales', 'Returns' => 'returns', 'Net Sales' => 'net_sales' },
      'transaction_health_csv' => { 'Returns ($)' => 'returns_amount', 'Chargebacks ($)' => 'chargebacks_amount',
        'Retrievals ($)' => 'retrievals_amount', 'Returns (Count)' => 'returns_count',
        'Chargebacks (Count)' => 'chargebacks_count', 'Retrievals (Count)' => 'retrievals_count' }
    }.freeze
    MAX_BYTES = 1024 * 1024

    def self.call(text:, merchant:, kind:, year:, origin: 'https://nabankco.iriscrm.com')
      raise Client::Error, :invalid unless Current.tenant&.status == 'active' && Client.merchants(merchant) == [merchant] && Client::ORIGIN_PATTERN.match?(origin)
      raise Client::Error, :response unless METRICS.key?(kind) && text.is_a?(String) && text.bytesize.between?(1, MAX_BYTES)

      csv = CSV.parse(text.delete_prefix("\uFEFF"), field_size_limit: 4096).reject { |row| row.all?(&:blank?) }
      raise Client::Error, :response if csv.empty? || csv.size > 200

      rows = csv.first == %w[period metric value] ? long_rows(csv.drop(1), kind) : matrix_rows(csv, kind, year)
      raise Client::Error, :response if rows.empty? || rows.map { |row| [row['period'], row['metric']] }.uniq.size != rows.size

      groups = rows.group_by { |row| row.fetch('period') }
      groups.each_value do |group|
        raise Client::Error, :response unless group.map { |row| row['metric'] }.sort == METRICS.fetch(kind).values.sort
        next unless kind == 'sales_health_csv'

        values = group.to_h { |row| [row['metric'], BigDecimal(row['value'])] }
        raise Client::Error, :response unless (values['gross_sales'] - values['returns'] - values['net_sales']).abs <= BigDecimal('0.01')
      end
      observed_at = Time.current
      IrisReport.transaction do
        groups.each do |period, group|
          date = Date.iso8601("#{period}-01")
          identity = { api_origin: origin, merchant_number: merchant, report_kind: kind,
            window_from: date, window_to: date.end_of_month }
          IrisReport.find_or_initialize_by(identity).update!(status: 'complete', payload_json: { 'data' => group }.to_json,
            source_digest: Digest::SHA256.hexdigest(text), observed_at: observed_at)
        end
      end
      groups.size
    rescue CSV::MalformedCSVError, ArgumentError, TypeError, EncodingError
      raise Client::Error, :response
    end

    def self.long_rows(rows, kind)
      rows.map do |row|
        raise Client::Error, :response unless row.size == 3 && row[0].to_s.match?(/\A[0-9]{4}-[0-9]{2}\z/) && METRICS.fetch(kind).value?(row[1])

        Date.iso8601("#{row[0]}-01")
        { 'period' => row[0], 'metric' => row[1], 'value' => value(row[2], row[1]) }
      end
    end

    def self.matrix_rows(rows, kind, year)
      year = Integer(year.to_s, 10)
      raise Client::Error, :response unless year.between?(2000, 2100)

      header = rows.shift
      labels = header.drop(1).reject { |label| label == 'Total' }
      months = labels.map { |label| Date::MONTHNAMES.index(label) }
      raise Client::Error, :response unless months.size.between?(1, 12) && months.all? && months.uniq.size == months.size
      raise Client::Error, :response unless months.each_cons(2).all? { |a, b| b == a % 12 + 1 }

      periods = months.map { |month| Date.new(month > months.last ? year - 1 : year, month, 1).strftime('%Y-%m') }
      rows.flat_map do |row|
        next [] if row.first == 'Net Sales % Increase (Year over Year)'
        if row.first == 'Volume (Count)'
          raise Client::Error, :response unless row.drop(1) == header.drop(1)

          next []
        end

        metric = METRICS.fetch(kind)[row.first]
        raise Client::Error, :response unless metric && row.size == header.size

        periods.each_with_index.map { |period, index| { 'period' => period, 'metric' => metric, 'value' => value(row[index + 1], metric) } }
      end
    end

    def self.value(text, metric)
      raw = text.to_s.strip.delete('$,')
      raw = "-#{raw[1...-1]}" if raw.start_with?('(') && raw.end_with?(')')
      raise Client::Error, :response unless raw.match?(/\A-?[0-9]+(?:\.[0-9]{1,2})?\z/)

      number = BigDecimal(raw)
      raise Client::Error, :response unless number.finite? && number.abs < 10**15
      raise Client::Error, :response if metric.end_with?('_count') && (number.negative? || number != number.to_i)

      number.to_s('F')
    end
  end
end
