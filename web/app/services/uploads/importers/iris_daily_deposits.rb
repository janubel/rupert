# frozen_string_literal: true

module Uploads
  module Importers
    # The NAB / IRIS native Daily Deposits CSV (IrisReporting::DailyDepositsCsvImport):
    # batch summaries kept as a report snapshot, never individual sales.
    class IrisDailyDeposits < Base
      importer 'iris_daily_deposits', label: 'NAB / IRIS Daily Deposits CSV', source: 'NAB / IRIS', permission: 'settings.write', formats: %w[csv],
        errors: [ArgumentError, ::IrisReporting::Client::Error]

      def self.destination_label = 'POS & payments → IRIS reporting'

      def self.params_spec(_document = nil, _detection = nil)
        [
          { name: 'merchant', label: 'Merchant number', type: :text, required: true, hint: 'Digits only, as shown in IRIS.' },
          { name: 'period', label: 'Report month', type: :text, required: true, hint: 'YYYY-MM. Must match the dates in the file.' }
        ]
      end

      def suggested_params(document, _detection)
        first_date = document.rows(10).map { |row| row.first.to_s }.find { |cell| cell.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z}) }
        month, _day, year = first_date.to_s.split('/')
        first_date ? { 'period' => format('%<y>04d-%<m>02d', y: year.to_i, m: month.to_i) } : {}
      end

      def detect(document)
        first = document.rows(3).reject { |row| row.all?(&:blank?) }
        return nil unless first.first == ['Daily Deposits'] && first[1].to_a.first.to_s.start_with?('Records exported:')

        detection('iris_daily_deposits', 'NAB / IRIS Daily Deposits', 0.99,
          'The file starts with “Daily Deposits” and a “Records exported” line, the native IRIS layout.')
      end

      def dry_run(document, params, _upload)
        merchant = validated_merchant(params)
        payload = ::IrisReporting::DailyDepositsCsvImport.parse(text: text!(document), period: params['period'])
        totals = payload.fetch('totals')
        outcome("The file matches the native Daily Deposits layout for #{params['period']}. Approving saves a report snapshot for merchant #{merchant}; no sale is created.",
          counts: { 'Deposit rows' => totals.fetch('records'), 'Transactions' => totals.fetch('transactions'), 'Total' => totals.fetch('amount') })
      rescue ::IrisReporting::Client::Error => e
        raise ArgumentError, friendly(e)
      end

      def import!(document, params, _upload, actor:)
        merchant = validated_merchant(params)
        report = ::IrisReporting::DailyDepositsCsvImport.call(text: text!(document), merchant: merchant, period: params['period'])
        outcome('Daily Deposits snapshot saved. No sales or inventory changed.', counts: { 'Report' => "##{report.id}" }, path: helpers.pos_connection_path('iris_reporting'))
      rescue ::IrisReporting::Client::Error => e
        raise ArgumentError, friendly(e)
      end

      private

      def validated_merchant(params)
        merchant = params['merchant'].to_s.strip
        raise ArgumentError, 'Enter the merchant number (digits only).' unless ::IrisReporting::Client.merchants(merchant) == [merchant]

        merchant
      rescue ::IrisReporting::Client::Error
        raise ArgumentError, 'Enter one merchant number (digits only).'
      end

      def friendly(error)
        "The file does not match the native Daily Deposits CSV for that merchant and month (#{error.message}). Use the original export and its own report month."
      end
    end
  end
end
