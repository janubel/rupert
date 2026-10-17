# frozen_string_literal: true

require 'csv'

module Finance
  # Exports posted journal entries in formats accountants and accounting
  # software can import (roadmap F40). Read-only. Amounts are dollars; debits
  # are positive, credits negative in IIF, and split into Debits/Credits columns
  # in CSV. Only `posted` entries are exported, so voids never appear.
  class LedgerExport
    Format = Struct.new(:key, :label, :extension, :content_type, keyword_init: true)

    FORMATS = [
      Format.new(key: 'iif', label: 'QuickBooks IIF (journal)', extension: 'iif',
                 content_type: 'text/plain'),
      Format.new(key: 'csv', label: 'Journal CSV (debits/credits)', extension: 'csv',
                 content_type: 'text/csv')
    ].freeze

    def initialize(from:, to:)
      @from = from
      @to = to
    end

    def entries
      @entries ||= JournalEntry.posted.in_range(@from, @to)
                             .includes(journal_lines: :account)
                             .order(:posted_on, :id).to_a
    end

    def format_for(key) = FORMATS.find { |f| f.key == key } || FORMATS.first

    def render(key)
      fmt = format_for(key)
      case fmt.key
      when 'iif' then iif
      else journal_csv
      end
    end

    def filename(key)
      f = format_for(key)
      "rupert-journal-#{@from}-#{@to}.#{f.extension}"
    end

    private

    # QuickBooks IIF general-journal import. Each balanced entry is one TRNS
    # block: the first line is the TRNS row, the rest are SPL rows, then
    # ENDTRNS. Amount is signed (debit positive, credit negative) in dollars.
    def iif
      lines = ["!TRNS\tTRNSID\tDATE\tACCNT\tAMOUNT\tMEMO", "!SPL\tSPLID\tDATE\tACCNT\tAMOUNT\tMEMO"]
      entries.each do |entry|
        rows = entry.journal_lines.sort_by(&:position)
        rows.each_with_index do |line, index|
          tag = index.zero? ? 'TRNS' : 'SPL'
          amount = (line.debit_cents.to_i - line.credit_cents.to_i) / 100.0
          memo = [entry.memo, line.memo].compact.reject(&:blank?).join(' · ').gsub(/[\t\r\n]/, ' ')
          lines << [tag, entry.id, entry.posted_on.strftime('%m/%d/%Y'),
                    "#{line.account.code} #{line.account.name}", format('%.2f', amount), memo].join("\t")
        end
        lines << 'ENDTRNS'
      end
      lines.join("\r\n") + "\r\n"
    end

    # Generic, accountant-friendly CSV: one row per line, entry id and date on
    # every row, with separate Debits and Credits columns. Imports into Xero,
    # Wave, Sage and most bookkeeping tools.
    def journal_csv
      CSV.generate do |csv|
        csv << %w[JournalNo Date AccountCode AccountName Debits Credits Description]
        entries.each do |entry|
          entry.journal_lines.sort_by(&:position).each do |line|
            csv << [
              entry.id,
              entry.posted_on.iso8601,
              line.account.code,
              line.account.name,
              cents(line.debit_cents),
              cents(line.credit_cents),
              [entry.memo, line.memo].compact.reject(&:blank?).join(' · ')
            ]
          end
        end
      end
    end

    def cents(value) = format('%.2f', value.to_i / 100.0)
  end
end
