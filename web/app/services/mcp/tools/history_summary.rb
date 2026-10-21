# frozen_string_literal: true

module Mcp
  module Tools
    class HistorySummary < Tool
      tool 'history_summary',
        title: 'History coverage by source',
        description: 'What history Rupert holds, and from where: for QuickBooks, Shopify, Square, C-Trax, SwipeSimple, NAB/IRIS, ' \
                     'Authorize.net, bank statements and the ledger, the earliest and latest dates, record counts (per year), when each ' \
                     'last arrived, calendar months with no records and sources whose date spans overlap. Counts and dates only: never ' \
                     'amounts, names or raw rows. A source\'s oldest record is the coverage available, not proof of when the business ' \
                     'began; an empty month may be quiet or missing. Pass year to see just that year. Same data as the History page. Read-only.',
        scope: 'finance:read'

      input_schema(
        type: 'object',
        properties: {
          year: { type: 'integer', minimum: 1990, maximum: 2099, description: 'Optional calendar year, for example 2025, to answer "what do we have for that year".' }
        },
        additionalProperties: false
      )

      def call(args)
        year = args['year']&.to_s
        sources = ::HistorySummary.call.map do |source|
          row = {
            key: source.key, source: source.label, unit: source.unit, records: source.records,
            earliest: source.first_date&.iso8601, latest: source.last_date&.iso8601, last_arrived: iso(source.last_import_at),
            empty_months: source.gap_months.first(12), empty_months_total: source.gap_total,
            same_dates_as: source.overlaps.map { |o| o['label'] }, records_by_year: source.by_year, caution: source.caveat
          }
          row[:records_in_year] = source.by_year.fetch(year, 0) if year
          row
        end
        data = { year: year&.to_i, sources: sources,
                 note: 'Counts are records Rupert stores, not sales totals. The earliest date is the coverage available, not the business start.' }
        text = if year
          held = sources.select { |row| row[:records_in_year].to_i.positive? }
          none = sources.reject { |row| row[:records_in_year].to_i.positive? }.map { |row| row[:source] }
          "For #{year}: #{held.empty? ? 'no source holds records' : held.map { |row| "#{row[:source]} #{row[:records_in_year]} #{row[:unit]}" }.join('; ')}. " \
            "#{none.empty? ? '' : "Nothing held from #{none.to_sentence}. "}That is what Rupert retains, not proof nothing else exists."
        else
          sources.select { |row| row[:records].positive? }.map { |row| "#{row[:source]}: #{row[:earliest]} to #{row[:latest]}, #{row[:records]} #{row[:unit]}" }.join('; ').presence || 'No history is retained yet.'
        end
        result(text, data)
      end
    end
  end
end
