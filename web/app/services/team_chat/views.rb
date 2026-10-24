# frozen_string_literal: true

module TeamChat
  # Views a bot builds with show_view: a table, a bar or line chart, or a small HTML page, opened beside the chat.
  # Only data travels: the page draws tables and charts itself, and HTML is cleaned (no scripts, styles, links out
  # or outside images) and shown in a sandboxed frame. Numbers that are not in the bot's tool results are counted
  # as unchecked and flagged in the panel.
  module Views
    KINDS = %w[table bar_chart line_chart html].freeze
    MAX_VIEWS = 3
    MAX_COLUMNS = 12
    MAX_ROWS = 200
    MAX_CELL = 200
    MAX_HTML = 20_000
    HTML_TAGS = %w[table thead tbody tfoot tr th td caption p br hr h2 h3 h4 ul ol li strong em b i small code pre span div section header].freeze
    HTML_ATTRIBUTES = %w[colspan rowspan].freeze

    SCHEMA = {
      type: 'object',
      properties: {
        title: { type: 'string', maxLength: 80, description: 'Short title shown on the button and the panel.' },
        kind: { type: 'string', enum: KINDS, description: 'table, bar_chart, line_chart (first column = labels, the next columns = numbers) or html.' },
        columns: { type: 'array', maxItems: MAX_COLUMNS, items: { type: 'string', maxLength: 40 }, description: 'Column headings (table and charts).' },
        rows: { type: 'array', maxItems: MAX_ROWS, items: { type: 'array', maxItems: MAX_COLUMNS, items: { type: %w[string number null] } },
                description: 'One array per row, in column order. Copy figures exactly from tool results.' },
        html: { type: 'string', maxLength: MAX_HTML, description: 'For kind html only: simple markup (tables, lists, headings, paragraphs). No scripts, styles or links.' },
        note: { type: 'string', maxLength: 300, description: 'One line under the view: what it covers (source, period).' }
      },
      required: %w[title kind],
      additionalProperties: false
    }.freeze

    DESCRIPTION = 'Shows a table, bar chart, line chart or small HTML page beside the chat (a button under your reply opens it). ' \
                  'Use it when a comparison or list is clearer laid out than in a sentence, for example several days, stores or ' \
                  'products side by side. Copy every figure exactly from tool results; figures that are not in them are flagged. ' \
                  'Say in your reply what the view shows.'

    module_function

    # A clean view from the tool's arguments, or raises ArgumentError with what to fix.
    def build(args, known_text: '')
      kind = args['kind'].to_s
      raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)

      view = { 'id' => SecureRandom.hex(4), 'title' => args['title'].to_s.squish.first(80).presence || 'View', 'kind' => kind,
               'note' => args['note'].to_s.squish.first(300).presence }
      if kind == 'html'
        html = sanitize(args['html'].to_s.first(MAX_HTML))
        raise ArgumentError, 'html is empty after cleaning; use tables, lists, headings and paragraphs' if html.blank?

        view['html'] = html
        figures = html_text(html)
      else
        columns = Array(args['columns']).first(MAX_COLUMNS).map { |column| column.to_s.squish.first(40) }
        rows = Array(args['rows']).first(MAX_ROWS).map { |row| Array(row).first(columns.size.nonzero? || MAX_COLUMNS).map { |cell| clean_cell(cell) } }
        raise ArgumentError, 'a table or chart needs columns and at least one row' if columns.empty? || rows.empty?
        if kind != 'table' && rows.none? { |row| row.drop(1).any? { |cell| cell.is_a?(Numeric) || number?(cell) } }
          raise ArgumentError, 'a chart needs numbers after the first (label) column'
        end

        view['columns'] = columns
        view['rows'] = rows
        figures = rows.flat_map { |row| row.map(&:to_s) }.join("\n")
      end
      view['unchecked'] = unchecked(figures, known_text)
      view.compact
    end

    def clean_cell(cell)
      return cell if cell.is_a?(Numeric) && cell.to_f.finite?
      return nil if cell.nil?

      AskRupert::Redactor.clean(cell.to_s).squish.first(MAX_CELL)
    end

    def number?(value) = value.to_s.strip.match?(/\A[-−]?\$?\d[\d,]*(?:\.\d+)?%?\z/)

    DROPPED = %w[script style noscript template iframe object embed svg math form head title].freeze

    # Elements whose content is code or outside the page are dropped with their content; the rest keeps only
    # HTML_TAGS and HTML_ATTRIBUTES (no styles, links, images or event handlers).
    def sanitize(html)
      fragment = Nokogiri::HTML.fragment(html)
      fragment.css(DROPPED.join(',')).each(&:remove)
      Rails::HTML5::SafeListSanitizer.new.sanitize(fragment.to_html, tags: HTML_TAGS, attributes: HTML_ATTRIBUTES).to_s.strip
    end

    def html_text(html) = Nokogiri::HTML.fragment(html).text

    # How many figures (money, percentages and plain numbers of two or more digits) are not in the tool results.
    def unchecked(text, known_text)
      figures = text.to_s.scan(/(?<![\w.])[-−]?\$?\d[\d,]*(?:\.\d+)?%?/).map { |raw| raw.delete('$,%−-') }.reject { |raw| raw.delete('.').length < 2 }
      return 0 if figures.empty?

      known = NumberCheck.known_values(known_text.to_s)
      figures.count { |raw| known.none? { |value| (value.abs - raw.to_f).abs < 0.005 } }
    end
  end
end
