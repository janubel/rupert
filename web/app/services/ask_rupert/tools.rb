# frozen_string_literal: true

module AskRupert
  # The only things the model can ask Rupert to do. Each runs in this process as
  # the signed-in person: it can read what that person can read and write nothing
  # except a *draft* report that the person must send themselves. A tool that the
  # person is not allowed to use is not offered to the model and is refused again
  # when called. Results are data for the model to summarise, never instructions.
  #
  # The audit trail records the tool name, outcome and time only, never what was
  # asked or returned.
  class Tools
    MAX_RESULT_CHARS = 5_000
    REPORT_TOOLS = %w[sales_summary sales_tax_report inventory_search stock_comparison swipesimple_items
                      time_keeping_report list_tasks list_alerts list_reports list_uploads history_summary].freeze
    REPORT_KINDS = %w[bug request question].freeze
    # What may be offered where other people can read the reply (a shared chat room):
    # navigation help only, never records, figures or settings.
    SHARED_AUDIENCE_TOOLS = %w[where_is how_do_i].freeze

    Result = Struct.new(:ok, :text, :links, :draft, keyword_init: true)
    Definition = Struct.new(:name, :description, :properties, :required, :gate, :handler, keyword_init: true)

    class Refused < StandardError; end

    attr_reader :used

    # audience: :private (the signed-in person is the only reader, every tool they may use),
    # :direct_help (only they read it, but the answer is navigation help only, as in a direct message)
    # or :shared (others read the reply, navigation help that reveals nothing about this person's access).
    def initialize(user:, conversation: nil, message: nil, audience: :private)
      raise ArgumentError, "unknown audience #{audience.inspect}" unless %i[private direct_help shared].include?(audience)

      @audience = audience
      @user = user
      @conversation = conversation
      @message = message
      @guide = Guide.new(user)
      @token = ScopedToken.new(user)
      @used = 0
    end

    def definitions
      @definitions ||= all_definitions.select { |definition| audience_allows?(definition.name) && definition.gate.call }
    end

    def names = definitions.map(&:name)

    # The tool list as the model sees it.
    def prompt_section
      lines = definitions.map do |definition|
        args = definition.properties.map { |key, spec| "#{key}#{'*' if definition.required.include?(key)}: #{spec[:description]}" }.join('; ')
        "- #{definition.name}(#{args}) — #{definition.description}"
      end
      lines << "  Reports you can run with run_report: #{report_tools.map(&:tool_name).join(', ')}" if report_tools.any?
      lines.join("\n")
    end

    # Details for the report tools, so the model knows each one's arguments.
    def report_reference
      report_tools.map do |tool|
        props = tool.input_schema[:properties].except(:page, :per_page).map do |key, spec|
          "#{key}#{spec[:enum] ? " (#{spec[:enum].join('|')})" : ''}"
        end.join(', ')
        "- #{tool.tool_name}: #{tool.description.to_s.split('. ').first.to_s.first(160)}. Arguments: #{props.presence || 'none'}"
      end.join("\n")
    end

    # Runs one tool call. Always returns a Result; failures come back as text for the model.
    def call(name, arguments)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @used += 1
      definition = definitions.find { |candidate| candidate.name == name.to_s }
      return finish(name, started, 'unknown', Result.new(ok: false, text: "No tool named #{name.to_s.first(40)}. Use one of: #{names.join(', ')}.", links: [])) unless definition

      args = arguments.is_a?(Hash) ? arguments.stringify_keys : {}
      schema = { type: 'object', properties: definition.properties, required: definition.required, additionalProperties: false }
      coerced, problems = Mcp::SchemaValidator.call(schema, args)
      return finish(name, started, 'invalid', Result.new(ok: false, text: "Invalid arguments: #{problems.first(3).join(' ')}", links: [])) if problems.any?

      result = send(definition.handler, coerced)
      finish(name, started, result.ok ? 'ok' : 'error', result)
    rescue Refused => e
      finish(name, started, 'denied', Result.new(ok: false, text: e.message, links: []))
    rescue Mcp::ToolError => e
      finish(name, started, 'error', Result.new(ok: false, text: e.message.to_s.first(400), links: []))
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { ask_rupert_tool: name.to_s.first(40) })
      finish(name, started, 'error', Result.new(ok: false, text: 'That lookup failed. Tell the person you could not check it and suggest the page itself.', links: []))
    end

    private

    def audience_allows?(name)
      @audience == :private || SHARED_AUDIENCE_TOOLS.include?(name)
    end

    def all_definitions
      [
        Definition.new(name: 'where_is', handler: :where_is, required: %w[query], gate: -> { true },
          description: 'Finds the pages and menus in Rupert this person can open for a topic, with links.',
          properties: { 'query' => { type: 'string', minLength: 1, maxLength: 120, description: 'What they are looking for, e.g. "timesheets"' } }),
        Definition.new(name: 'how_do_i', handler: :how_do_i, required: %w[query], gate: -> { true },
          description: 'Finds Learn Rupert lessons (with steps) and definitions for a task or word.',
          properties: { 'query' => { type: 'string', minLength: 1, maxLength: 120, description: 'The task or word, e.g. "count stock"' } }),
        Definition.new(name: 'search', handler: :search, required: %w[query], gate: -> { @user.can?('dashboard.read') },
          description: 'Finds orders, customers, SKUs and staff this person may see. Contact details are hidden from you.',
          properties: { 'query' => { type: 'string', minLength: 2, maxLength: 80, description: 'An order number, name or SKU' } }),
        Definition.new(name: 'run_report', handler: :run_report, required: %w[report], gate: -> { report_tools.any? },
          description: 'Runs one quick read-only report as this person and returns its numbers.',
          properties: { 'report' => { type: 'string', maxLength: 40, description: 'A report name from the list below' },
                        'arguments' => { type: 'object', description: 'That report’s arguments; dates are YYYY-MM-DD' } }),
        Definition.new(name: 'system_status', handler: :system_status, required: [], gate: -> { status_sections.any? },
          description: "Shows #{status_sections.to_sentence} for the people allowed to see them.",
          properties: {}),
        Definition.new(name: 'file_report', handler: :file_report, required: %w[kind summary], gate: -> { @conversation && @user.active? },
          description: 'Prepares a bug, request or question report for the Rupert team. It is only a draft: the person reviews it and presses Send. Use when you cannot help or they ask.',
          properties: { 'kind' => { type: 'string', enum: REPORT_KINDS, description: 'bug, request or question' },
                        'summary' => { type: 'string', minLength: 3, maxLength: 200, description: 'One line' },
                        'details' => { type: 'string', maxLength: 2000, description: 'What they tried and what happened or is wanted' } })
      ]
    end

    def finish(name, started, outcome, result)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      ActivityLogger.log('ask_rupert_tool', actor: @user,
        details: "tool=#{name.to_s.gsub(/[^\w]/, '?').first(30)}; outcome=#{outcome}; duration_ms=#{ms}; conversation=#{@conversation&.id}")
      result.text = result.text.to_s.first(MAX_RESULT_CHARS)
      result
    end

    def report_tools
      @report_tools ||= REPORT_TOOLS.filter_map { |name| Mcp::Registry.find(name) }.select { |tool| tool.available_to?(@token) }
    end

    def status_sections
      @status_sections ||= [
        ('sync' if @user.can?('sync.read')),
        ('updates' if AutoUpdate.manager?(@user)),
        ('backups' if @user.super_admin?)
      ].compact.unshift('this build')
    end

    # --- handlers ---

    def where_is(args)
      found = @guide.where_is(args['query'])
      lines = found[:pages].map do |page|
        "- #{page[:title]}#{" (#{page[:area]})" if page[:area]}: #{page[:path]}#{" — lesson: #{page[:lesson][:title]} #{page[:lesson][:path]}" if page[:lesson]}"
      end
      lines += found[:elsewhere].map { |extra| "- #{extra[:title]}: #{extra[:where]}" }
      # Which pages are not someone's would show the shape of their access to everyone reading.
      lines += found[:not_available].map { |name| "- #{name}: exists in Rupert but is not part of this person’s access; they can ask an administrator." } unless @audience == :shared
      lines = ['No matching page for this person. Try other words, or suggest the search (/) or Learn Rupert (/learning).'] if lines.empty?
      links = found[:pages].map { |page| { title: page[:title], path: page[:path], kind: 'page' } } +
              found[:pages].filter_map { |page| page[:lesson]&.then { |lesson| { title: lesson[:title], path: lesson[:path], kind: 'lesson' } } }
      Result.new(ok: true, text: lines.join("\n"), links: links)
    end

    def how_do_i(args)
      found = @guide.how_do_i(args['query'])
      parts = found[:lessons].map do |lesson|
        steps = lesson[:steps].each_with_index.map { |step, index| "  #{index + 1}. #{step}" }.join("\n")
        "Lesson “#{lesson[:title]}” (#{lesson[:minutes]} min) #{lesson[:path]}\n#{lesson[:summary]}\n#{steps}#{"\n  Opens: #{lesson[:opens]}" if lesson[:opens]}"
      end
      parts += found[:terms].map { |term| "Definition — #{term[:term]}: #{term[:definition]}" }
      parts = ['No lesson matches. Try where_is, or say you are not sure and offer to prepare a report.'] if parts.empty?
      links = found[:lessons].map { |lesson| { title: lesson[:title], path: lesson[:path], kind: 'lesson' } }
      Result.new(ok: true, text: parts.join("\n\n"), links: links)
    end

    def search(args)
      raise Refused, 'Search needs dashboard access, which this person does not have.' unless @user.can?('dashboard.read')

      rows = SearchService.search(args['query'], limit: 8)
      return Result.new(ok: true, text: 'No results.', links: []) if rows.empty?

      text = rows.map { |row| "- #{row.type}: #{Redactor.personal(row.label)} — #{Redactor.personal(row.sub_label)} #{row.path}" }.join("\n")
      links = rows.first(4).map { |row| { title: Redactor.personal(row.label), path: row.path, kind: row.type } }
      Result.new(ok: true, text: text, links: links)
    end

    def run_report(args)
      tool = report_tools.find { |candidate| candidate.tool_name == args['report'] }
      raise Refused, "No report called #{args['report'].to_s.first(40)} is available to this person. Available: #{report_tools.map(&:tool_name).join(', ')}." unless tool

      raw = args['arguments'].is_a?(Hash) ? args['arguments'].stringify_keys : {}
      coerced, problems = Mcp::SchemaValidator.call(tool.input_schema, raw)
      raise Refused, "Invalid report arguments: #{problems.first(3).join(' ')}" if problems.any?

      outcome = tool.new(token: @token).call(coerced)
      body = "#{outcome.text}\n#{JSON.generate(outcome.data)}"
      page = Mcp::Tools::ListReports::REPORTS.find { |report| report[:tool] == tool.tool_name }
      links = page ? [{ title: page[:title], path: page[:path], kind: 'report' }] : []
      Result.new(ok: true, text: Redactor.personal(body), links: links)
    end

    def system_status(_args)
      lines = ["Build: #{BuildInfo.current.label}#{" built #{BuildInfo.current.built_at.strftime('%Y-%m-%d %H:%M UTC')}" if BuildInfo.current.built_at}"]
      lines << sync_line if @user.can?('sync.read')
      lines << update_line if AutoUpdate.manager?(@user)
      lines << backup_line if @user.super_admin?
      Result.new(ok: true, text: lines.compact.join("\n"), links: [])
    end

    def sync_line
      run = SyncRun.where(tenant_id: Current.tenant_id).order(startedAt: :desc).first
      return 'Sync: no runs recorded yet.' unless run

      "Sync: last run #{run.status} at #{run.startedAt.utc.strftime('%Y-%m-%d %H:%M UTC')} (source #{run.source || 'all'}). A recorded run is not proof every record arrived."
    end

    def update_line
      pending = UpdateChecker.pending
      pending ? "Updates: #{pending.behind_by} newer change#{'s' unless pending.behind_by == 1} on GitHub; review under System → Updates." : 'Updates: this build is current.'
    end

    def backup_line
      log = BackupLog.where(tenant_id: Current.tenant_id).order(startedAt: :desc).first
      return 'Backups: none recorded yet.' unless log

      "Backups: last attempt #{log.status} at #{log.startedAt.utc.strftime('%Y-%m-%d %H:%M UTC')}."
    end

    def file_report(args)
      draft = {
        'kind' => args['kind'], 'summary' => AgentFeedback.clean(args['summary'], 200),
        'details' => AgentFeedback.clean(args['details'], 2000, multiline: true).to_s
      }
      Result.new(ok: true, draft: draft, links: [],
        text: 'Draft prepared. A card with a Send report button is now shown to the person. Tell them to read it and press Send report; ' \
              'nothing is filed until they do. Do not say it was already sent.')
    end
  end
end
