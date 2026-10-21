# frozen_string_literal: true

require 'bigdecimal'
require 'csv'

module SwipesimpleWeb
  # Parses SwipeSimple's Reporting → tax / sales CSV for one requested date
  # range and proves the parse before anything is stored: exact headers, every
  # day inside the range, no duplicate day (or day + rate), and for every money
  # column the day rows add up to SwipeSimple's own Totals row. Blank amounts
  # stay nil (unknown), never zero. Anything unexpected fails the whole file.
  class ReportCsv
    class Error < StandardError; end

    HEADERS = {
      'tax' => ['Date', 'Tax Rate', 'Pre-Tax Subtotal', 'Total $ of Sales Tax', 'Total $ of Sales'],
      'sales' => ['Date', 'Subtotals', 'Discounts', 'Sales Taxes', 'Tips', 'Refunds', 'Total Net Sales', 'Total Net Card', 'Total Net Cash']
    }.freeze
    MONEY = {
      'tax' => { 'Pre-Tax Subtotal' => :pre_tax_cents, 'Total $ of Sales Tax' => :tax_cents, 'Total $ of Sales' => :total_cents },
      'sales' => { 'Subtotals' => :subtotal_cents, 'Discounts' => :discounts_cents, 'Sales Taxes' => :tax_cents, 'Tips' => :tips_cents,
                   'Refunds' => :refunds_cents, 'Total Net Sales' => :net_sales_cents, 'Total Net Card' => :net_card_cents, 'Total Net Cash' => :net_cash_cents }
    }.freeze
    MAX_ROWS = 5_000

    def self.parse(text, topic:, from:, to:)
      new(text, topic, from, to).rows
    end

    # Accepts 1234.56, 1,234.56, $1,234.56, -$5.00, $-5.00, ($5.00) and .50.
    def self.cents(value)
      text = value.to_s.strip
      return nil if text.empty?

      negative = false
      if (inner = text[/\A\((.*)\)\z/, 1])
        negative = true
        text = inner.strip
      end
      2.times do |step|
        text = text.delete_prefix('$').strip if step == 1
        next unless text.start_with?('-')
        raise Error, "Unrecognised amount #{value.to_s.first(20).inspect}." if negative

        negative = true
        text = text[1..].strip
      end
      match = text.match(/\A(\d{1,3}(?:,\d{3})+|\d+)?(?:\.(\d{1,2}))?\z/)
      raise Error, "Unrecognised amount #{value.to_s.first(20).inspect}." unless match && (match[1] || match[2]) && match[1].to_s.delete(',').length <= 13

      cents = (match[1].to_s.delete(',').to_i * 100) + match[2].to_s.ljust(2, '0').to_i
      negative ? -cents : cents
    end

    # "PA Tax Rate (6.0%)" → 6.0; labels without a percent (e.g. "No Tax") → nil.
    def self.percent(label)
      raw = label.to_s[/(\d{1,3}(?:\.\d{1,4})?)\s*%/, 1]
      return nil unless raw

      rate = BigDecimal(raw)
      raise Error, "Unrecognised tax rate #{label.to_s.first(40).inspect}." if rate > 100

      rate
    end

    def initialize(text, topic, from, to)
      raise ArgumentError, 'Unknown SwipeSimple report.' unless HEADERS.key?(topic)

      @text = text.to_s
      @topic = topic
      @from = from
      @to = to
    end

    def rows
      raise Error, 'The report is not UTF-8 text.' unless @text.valid_encoding?

      table = CSV.parse(@text.delete_prefix("﻿")).reject { |row| row.all? { |cell| cell.to_s.strip.empty? } }
      header = table.shift
      raise Error, 'The report headers changed.' unless header&.map { |cell| cell.to_s.strip } == headers
      raise Error, 'The report has too many rows.' if table.size > MAX_ROWS
      # A period with no sales comes back as the header row alone (verified on
      # the live tax export): no day rows and no Totals row.
      return [] if table.empty?

      totals = table.pop
      raise Error, 'The report has no Totals row.' unless totals && totals.first.to_s.strip == 'Totals'
      raise Error, 'A report row has the wrong number of columns.' unless (table + [totals]).all? { |row| row.size == headers.size }

      days = table.map { |row| day(row) }
      keys = days.map { |day| @topic == 'tax' ? [day[:business_date], day[:tax_rate_label]] : day[:business_date] }
      raise Error, 'The report repeats a day.' unless keys.uniq.size == keys.size

      check_totals!(days, totals)
      days
    rescue CSV::MalformedCSVError
      raise Error, 'The report is not a readable CSV.'
    end

    private

    def headers = HEADERS.fetch(@topic)

    def day(row)
      cells = row.map { |cell| cell.to_s.strip }
      date = date(cells[0])
      raise Error, "The report includes #{date}, outside #{@from}..#{@to}." unless date.between?(@from, @to)

      record = { business_date: date }
      if @topic == 'tax'
        label = cells[1]
        raise Error, 'A tax rate label is blank or too long.' if label.empty? || label.length > 100

        record[:tax_rate_label] = label
        record[:rate_percent] = self.class.percent(label)
      end
      MONEY.fetch(@topic).each { |header, field| record[field] = self.class.cents(cells[headers.index(header)]) }
      record
    end

    def date(value)
      match = value.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z})
      raise Error, "Unrecognised report date #{value.first(20).inspect}." unless match

      Date.new(match[3].to_i, match[1].to_i, match[2].to_i)
    rescue Date::Error
      raise Error, "Unrecognised report date #{value.first(20).inspect}."
    end

    def check_totals!(days, totals)
      MONEY.fetch(@topic).each do |header, field|
        total = self.class.cents(totals[headers.index(header)])
        values = days.map { |day| day[field] }
        consistent = total.nil? ? values.all?(&:nil?) : values.none?(&:nil?) && values.sum == total
        raise Error, "The #{header} days do not add up to SwipeSimple's Totals row." unless consistent
      end
    end
  end
end
