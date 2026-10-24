# frozen_string_literal: true

require 'bigdecimal'
require 'digest'
require 'json'

module TeamChat
  # Numeric resemblance is not evidence. Only explicit tool contracts produce
  # facts; Ruby renders their values AND meanings instead of trusting prose.
  module FinancialEvidence
    VERSION = 1
    CURRENCIES = %w[USD CAD EUR GBP AUD NZD CHF CNY HKD SGD MXN BRL ZAR INR].freeze
    TOOLS = %w[metric sales_summary period_review business_pulse sales_tax_report daily_close].freeze
    CONTRACTS = (TOOLS + %w[time_keeping_report]).freeze
    MEANINGS = {
      'gross_sales' => ['Gross sales (paid or fulfilled orders)', 'money'],
      'orders' => ['Paid or fulfilled order count', 'count'],
      'average_order_value' => ['Average gross order value', 'money'],
      'refund_rate' => ['Recorded refunds as a percentage of gross sales', 'percent'],
      'expenses_by_category' => ['Active expense-register total (not profit)', 'money'],
      'sales_by_source' => ['Gross sales by source', 'money']
    }.freeze
    DAILY_CLOSE = [['net_cents', 'Store net sales (gross minus refunds; before tax and tips)'],
                   ['gross_cents', 'Store gross sales (after discounts, before tax and tips)'],
                   ['cash_cents', 'Cash taken at the store'], ['card_cents', 'Card taken at the store'],
                   ['tax_cents', 'Sales tax collected at the store'], ['refunds_cents', 'Store refunds'],
                   ['tips_cents', 'Tips at the store']].freeze
    ORDER_SOURCE = 'canonical orders: Shopify, Square, Rupert POS and manual; C-Trax/SwipeSimple excluded'

    module_function

    def financial_data?(value)
      case value
      when Hash then value.any? { |key, inner| key.to_s.match?(/(?:_cents|_percent)\z/) || financial_data?(inner) }
      when Array then value.any? { |inner| financial_data?(inner) }
      else false
      end
    end

    def financial_text?(text)
      text.to_s.match?(/[$€£¥]|\d[\d,.]*\s*(?:%|dollars\b|[A-Z]{3}\b)|\b(?:USD|CAD|EUR|GBP|JPY)\s*-?\d/) ||
        (text.to_s.match?(/\d/) && text.to_s.match?(/\b(?:profit|revenue|sales|tax|expenses?|refunds?|margin|cash|balance|income)\b/i))
    end

    def build(tool:, data:, arguments:, tenant_id:, invocation:)
      data = data.deep_stringify_keys
      args = arguments.deep_stringify_keys
      out = { 'version' => VERSION, 'tool' => tool, 'tenant_id' => tenant_id, 'invocation' => invocation, 'facts' => [], 'gaps' => [] }
      case tool
      when 'metric'
        name = data['metric']
        raise ArgumentError unless name == args['name'] && MEANINGS.key?(name)

        expected = Metrics::Window.resolve(period: args['period'], from: args['from'], to: args['to'])
        period = window(data.fetch('period'), expected.from.iso8601, expected.to.iso8601)
        source = name == 'expenses_by_category' ? 'active Rupert expense register; vendor payments excluded' : order_source(data['source'])
        raise ArgumentError unless data['source'].presence == args['source'].presence

        if args['source'].present? && Array(data['values']).any? { |row| Array(row['sources']).any? { |part| part['source'] != args['source'] } }
          raise ArgumentError
        end
        metric_rows(out, data['values'], name, source, period, 'values')
        out['gaps'] << 'Category breakdowns are not certified by this contract; the expense total is shown separately.' if name == 'expenses_by_category'
        if data['compared_with']
          prior = { 'previous' => expected.previous, 'last_year' => expected.last_year }.fetch(args['compare'].presence || 'previous')
          old = window(data['compared_with'], prior.from.iso8601, prior.to.iso8601)
          metric_rows(out, data['compared_with']['values'], name, source, old, 'compared_with.values')
          Array(data['change']).each_with_index do |row, index|
            add(out, row['change_percent'], 'percent', row['currency'], source, period,
              "#{MEANINGS.fetch(name).first}: change versus #{old['from']} to #{old['to']} (not percentage points)", "change.#{index}.change_percent")
          end
        end
      when 'sales_summary'
        last = args['to'] || Date.current.iso8601
        first = args['from'] || (Date.iso8601(last) - 29).iso8601
        period = window(data, first, last)
        Array(data['lines']).each_with_index do |row, index|
          raise ArgumentError if args['source'].present? && row['source'] != args['source']

          source = order_source(row.fetch('source'))
          { 'gross_cents' => ['Gross sales (paid or fulfilled orders)', 'money'], 'tax_cents' => ['Order tax', 'money'], 'orders' => ['Paid or fulfilled order count', 'count'] }.each do |field, (meaning, unit)|
            add(out, row[field], unit, row['currency'], source, period, meaning, "lines.#{index}.#{field}")
          end
        end
        Array(data['totals_by_currency']).each_with_index do |row, index|
          add(out, row['gross_cents'], 'money', row['currency'], order_source(args['source']), period,
            'Gross sales total (paid or fulfilled orders)', "totals_by_currency.#{index}.gross_cents")
        end
        out['gaps'] << 'Daily and product breakdowns are not certified by this contract.' if data['daily'].present? || data['top_products'].present?
      when 'period_review'
        period = window(data, args['from'], args['to'])
        if args['from'].blank? && args['to'].blank?
          preset = TimeRangePicker.preset(args['period'].presence || 'yesterday', Date.current)
          raise ArgumentError unless preset && period == window({ 'from' => preset.from.iso8601, 'to' => [preset.to, Date.current].min.iso8601 })
        end
        Array(data['sales']).each_with_index do |row, index|
          add(out, row['gross_cents'], 'money', row['currency'], ORDER_SOURCE, period, 'Gross sales (paid or fulfilled orders)', "sales.#{index}.gross_cents")
        end
        out['gaps'] << 'Expenses without explicit currency, comparisons and other review sections are not certified by this contract.'
      when 'sales_tax_report'
        period = window(data, args['from'] || Date.current.beginning_of_month.iso8601, args['to'] || Date.current.iso8601)
        allowed = (args['sources'].presence || SalesTaxReport::SOURCES.keys).map { |key| SalesTaxReport::SOURCES.fetch(key) }
        Array(data['lines']).each_with_index do |row, index|
          raise ArgumentError unless allowed.include?(row['source']) && row['store'].present?

          store = row['store'].to_s
          if store.length > 256 || AskRupert::Redactor.personal(store) != store
            out['gaps'] << 'A store identity could not be displayed safely; its figures were omitted.'
            next
          end
          source = "#{row['source']} / store #{store.inspect}; separate source, never added across sources"
          { 'tax_collected' => 'Reported tax collected', 'tax_refunded' => 'Reported tax refunded', 'net_tax' => 'Net reported tax', 'estimated_tax' => 'Estimated tax (not reported tax)' }.each do |field, meaning|
            add(out, row[field], 'money', row['currency'], source, period, meaning, "lines.#{index}.#{field}")
          end
        end
      when 'daily_close'
        first = args['from'] || Date.current.iso8601
        period = window(data, first, args['to'] || first)
        rows = Array(data['stores']).each_with_index.filter_map do |row, index|
          store = row['store'].to_s
          if store.blank? || store.length > 120 || AskRupert::Redactor.personal(store) != store
            out['gaps'] << 'A store name could not be displayed safely; its figures were omitted.'
            next
          end
          Array(row['notes']).each { |note| out['gaps'] << "#{store}: #{AskRupert::Redactor.personal(note.to_s).first(240)}" }
          [row, index, "#{store}; in-person register, separate from online orders and from every other store"]
        end
        # Most useful first, so a long answer drops tips and refunds before net sales.
        DAILY_CLOSE.each do |field, meaning|
          rows.each { |row, index, source| add(out, row[field], 'money', row['currency'], source, period, meaning, "stores.#{index}.#{field}") }
        end
      when 'time_keeping_report'
        period = window(data, args['from'] || Date.current.beginning_of_month.iso8601, args['to'] || Date.current.end_of_month.iso8601)
        sales = data.fetch('sales_same_days')
        raise ArgumentError unless sales['available'] == true && window(sales) == period

        metric_rows(out, sales['gross_sales_by_currency'], 'gross_sales', ORDER_SOURCE, period, 'sales_same_days.gross_sales_by_currency')
        out['gaps'] << 'Time-keeping figures are outside this financial evidence contract.'
      when 'business_pulse'
        period = window({ 'from' => data['date'], 'to' => data['date'] }, Date.current.iso8601, Date.current.iso8601)
        metric_rows(out, data.dig('sales', 'gross_sales_by_currency'), 'gross_sales', ORDER_SOURCE, period, 'sales.gross_sales_by_currency')
        out['gaps'] << 'Non-sales pulse sections are not part of the financial evidence contract.'
      else
        out['gaps'] << 'This financial tool does not yet provide a certified evidence contract.'
      end
      out['gaps'] << 'No complete financial facts were returned; missing data does not prove zero.' if out['facts'].empty?
      out['gaps'].uniq!
      while JSON.generate(out).length > 5_500 || out['facts'].size > 12
        out['facts'].pop
        out['gaps'] |= ['Some facts were omitted to fit the response budget. Narrow the question for remaining figures.']
      end
      out['gaps'].uniq!
      out
    rescue ArgumentError, KeyError, TypeError, Date::Error
      { 'version' => VERSION, 'tool' => tool, 'tenant_id' => tenant_id, 'invocation' => invocation, 'facts' => [],
        'gaps' => ['Financial evidence has incomplete or inconsistent source, period, currency or meaning; no figures can be certified.'] }
    end

    def window(data, expected_from = nil, expected_to = nil)
      first = Date.iso8601(data.fetch('from'))
      last = Date.iso8601(data.fetch('to'))
      raise ArgumentError if last < first || (expected_from && first.iso8601 != expected_from) || (expected_to && last.iso8601 != expected_to)

      { 'from' => first.iso8601, 'to' => last.iso8601 }
    end

    def order_source(source)
      return ORDER_SOURCE if source.blank?
      raise ArgumentError unless Metrics::SOURCES.include?(source)

      "#{source} canonical orders (paid or fulfilled)"
    end

    def metric_rows(out, rows, name, source, period, path)
      meaning, unit = MEANINGS.fetch(name)
      Array(rows).each_with_index do |row, index|
        if name == 'sales_by_source'
          Array(row['sources']).each_with_index do |part, part_index|
            part_source = order_source(part.fetch('source'))
            add(out, part['gross_cents'], 'money', row['currency'], part_source, period, 'Gross sales (paid or fulfilled orders)', "#{path}.#{index}.sources.#{part_index}.gross_cents")
            add(out, part['share_percent'], 'percent', row['currency'], part_source, period, 'Share of gross sales in this currency', "#{path}.#{index}.sources.#{part_index}.share_percent")
          end
          next
        end
        add(out, row['value'], unit, row['currency'], source, period, meaning, "#{path}.#{index}.value")
      end
    end

    def add(out, value, unit, currency, source, period, meaning, path)
      unless value.is_a?(Numeric) && CURRENCIES.include?(currency)
        out['gaps'] << 'A figure with a missing value or currency was omitted; unknown is not zero.'
        return
      end
      raise ArgumentError if unit == 'money' && !value.is_a?(Integer)
      raise ArgumentError if unit == 'count' && (!value.is_a?(Integer) || value.negative?)

      decimal = BigDecimal(value.to_s)
      raise ArgumentError unless decimal.finite?

      decimal /= 100 if unit == 'money'
      fact = { 'meaning' => meaning, 'unit' => unit, 'value' => decimal.to_s('F'), 'currency' => currency,
               'source' => source, 'period' => period, 'timezone' => Time.zone.name, 'field' => path, 'tool' => out['tool'], 'tenant_id' => out['tenant_id'], 'invocation' => out['invocation'] }
      fact['id'] = Digest::SHA256.hexdigest(JSON.generate(fact)).first(16)
      out['facts'] << fact
    end

    def decode(text, tenant_id, tool: nil, invocation: nil)
      data = JSON.parse(text)
      return unless data.is_a?(Hash) && data['version'] == VERSION && data['tenant_id'] == tenant_id && data['facts'].is_a?(Array) && data['gaps'].is_a?(Array)
      return if (tool && data['tool'] != tool) || (invocation && data['invocation'] != invocation)
      return unless data['facts'].all? do |fact|
        fact.is_a?(Hash) && fact['tenant_id'] == tenant_id && fact['tool'] == data['tool'] && fact['invocation'] == data['invocation'] &&
          fact['id'] == Digest::SHA256.hexdigest(JSON.generate(fact.except('id'))).first(16)
      end

      data
    rescue JSON::ParserError, TypeError
      nil
    end

    # The bot's own wording, kept only when every figure in it is one of the checked facts: each money amount (to
    # the cent, in a currency the facts have), percentage and order count; no profit/margin wording; tax, refunds,
    # expenses or averages only when a fact means that; and period words (today, last month...) only when a fact
    # covers exactly that period. Then Ruby adds what the figures are (meaning, source, period) and any gaps.
    # Returns nil when the prose does not pass, so the caller renders the facts instead.
    RELABEL = /\b(?:profits?|margins?|net income|earnings|take[- ]home|cash flow|bottom line)\b/i
    CONCEPTS = { /\btax(?:es)?\b/i => /tax/i, /\brefund/i => /refund/i, /\bexpense/i => /expense/i, /\baverage\b/i => /average/i,
                 /\bshare\b/i => /share/i }.freeze
    PERIOD_WORDS = { 'today' => 'today', 'yesterday' => 'yesterday', 'this week' => 'this_week', 'last week' => 'last_week',
                     'this month' => 'this_month', 'last month' => 'last_month', 'this quarter' => 'this_quarter',
                     'last quarter' => 'last_quarter', 'this year' => 'year_to_date', 'last year' => 'last_year' }.freeze
    CODED_AMOUNT = /(?<![\w.])-?\d[\d,]*\.\d{2}\s?(?<code>[A-Z]{3})\b/
    ORDER_COUNT = /(?<![\w.$])(?<count>\d[\d,]*)\s+(?:(?:paid|fulfilled|online|shopify|square)\s+)*orders?\b/i

    def checked_prose(text, evidence, today: Date.current)
      facts = evidence.flat_map { |item| item['facts'] }
      prose = text.to_s.strip
      return nil if facts.empty? || prose.blank? || prose.match?(RELABEL)

      meanings = facts.map { |fact| fact['meaning'].to_s }
      return nil if CONCEPTS.any? { |word, meaning| prose.match?(word) && meanings.none? { |known| known.match?(meaning) } }
      return nil unless periods_match?(prose, facts, today)

      currencies = facts.map { |fact| fact['currency'] }.uniq
      return nil if prose.scan(CODED_AMOUNT).flatten.any? { |code| !currencies.include?(code) }

      money = facts.select { |fact| fact['unit'] == 'money' }
      checked = 0
      NumberCheck.figures_in(prose).each do |figure|
        pool = figure.kind == :percent ? facts.select { |fact| fact['unit'] == 'percent' } : money
        pool = pool.select { |fact| fact['currency'] == 'USD' } if figure.kind == :money && figure.text.include?('$')
        return nil unless pool.any? { |fact| figure_matches?(figure, fact) }

        checked += 1
      end
      counts = facts.select { |fact| fact['unit'] == 'count' }.map { |fact| BigDecimal(fact['value']) }
      prose.scan(ORDER_COUNT).flatten.each do |count|
        return nil unless counts.include?(BigDecimal(count.delete(',')))

        checked += 1
      end
      return nil if checked.zero?

      [prose, note(facts, evidence, today)].join("\n\n")
    end

    def figure_matches?(figure, fact)
      value = BigDecimal(fact['value']).abs
      shown = BigDecimal(figure.text[/\d[\d,]*(?:\.\d+)?/].delete(','))
      return (value - shown).abs <= BigDecimal('0.5') / (10**figure.decimals) if figure.kind == :percent
      return false unless figure.decimals == 2 || (figure.decimals.zero? && value.frac.zero?)

      value == shown
    end

    def periods_match?(prose, facts, today)
      spans = facts.map { |fact| [fact.dig('period', 'from'), fact.dig('period', 'to')] }.uniq
      PERIOD_WORDS.all? do |words, key|
        next true unless prose.match?(/\b#{words}(?:'s)?\b/i)

        window = Metrics::Window.resolve(period: key, today: today)
        spans.include?([window.from.iso8601, window.to.iso8601])
      rescue ArgumentError
        false
      end
    end

    # One short line per kind of figure: what it means, where it comes from and the period, written by Ruby.
    def note(facts, evidence, today)
      lines = facts.map { |fact| [fact['meaning'], source_label(fact['source']), period_label(fact['period'], today)] }.uniq.first(3).map do |meaning, source, period|
        "✓ #{meaning} · #{source} · #{period}"
      end
      (lines + evidence.flat_map { |item| item['gaps'] }.uniq).join("\n")
    end

    def source_label(source)
      source.to_s.sub(ORDER_SOURCE, 'Shopify, Square, Rupert POS and manual orders (not C-Trax or SwipeSimple)')
    end

    def period_label(period, today)
      from = Date.iso8601(period['from'].to_s)
      to = Date.iso8601(period['to'].to_s)
      return 'today' if from == today && to == today
      return 'yesterday' if from == today - 1 && to == today - 1
      return from.strftime('%b %-d, %Y') if from == to

      from.year == to.year ? "#{from.strftime('%b %-d')} – #{to.strftime('%b %-d, %Y')}" : "#{from.strftime('%b %-d, %Y')} – #{to.strftime('%b %-d, %Y')}"
    rescue Date::Error, TypeError
      "#{period['from']} to #{period['to']}"
    end

    def render(evidence)
      facts = evidence.flat_map { |item| item['facts'] }
      lines = facts.first(12).map do |fact|
        number = BigDecimal(fact.fetch('value'))
        whole, fraction = number.to_s('F').split('.')
        value = fact['unit'] == 'money' ? "#{whole}.#{fraction.to_s.ljust(2, '0')}" : number.to_s('F').delete_suffix('.0')
        value += '%' if fact['unit'] == 'percent'
        "- #{fact['meaning']}: #{value} #{fact['currency']} (#{fact['source']}; #{fact.dig('period', 'from')} to #{fact.dig('period', 'to')} #{fact['timezone']})."
      end
      lines.unshift('From Rupert’s records:') if lines.any?
      lines << 'I could not verify financial figures for this request.' if facts.empty?
      lines << 'Additional verified facts were omitted. Narrow the question for the remaining figures.' if facts.size > 12
      lines.concat(evidence.flat_map { |item| item['gaps'] }.uniq)
      lines.join("\n")
    end
  end
end
