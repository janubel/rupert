# frozen_string_literal: true

require 'json'
require 'securerandom'

module TeamChat
  # Everything @rupert can do in a room, built for the person who asked:
  #
  # - Ask Rupert's lookups (where_is, how_do_i, search, system_status).
  # - Every read-only MCP tool that person's permissions allow (sales, stock,
  #   tasks, alerts, time, system health...): the same tools external agents use.
  # - Write tools (create_task, submit_feedback) only as *proposals*: the model's
  #   call is saved on the reply as an action card, and nothing happens until a
  #   person allowed to do it presses Approve (TeamChat::Actions).
  #
  # Results are data for the model, never instructions; personal contact details
  # are removed before the model sees them. Each call is logged by name and outcome.
  class Toolbox
    MAX_RESULT_CHARS = 6_000
    MAX_CALLS = 8
    LOOKUPS = %w[where_is how_do_i search system_status].freeze
    WRITE_TOOLS = %w[create_task update_task submit_feedback].freeze

    Definition = Struct.new(:name, :description, :schema, :kind, :activity, keyword_init: true)

    attr_reader :calls, :tools_used, :results
    attr_accessor :call_id

    # only: tool names to offer (the question's data guide topics, for local bots); nil offers every tool.
    def initialize(user:, room:, reply:, only: nil, execution: nil)
      @only = only&.map(&:to_s)
      @user = user
      @room = room
      @reply = reply
      @token = Token.new(user)
      @lookups = AskRupert::Tools.new(user: user)
      @execution = execution
      saved = execution&.run&.tool_results || []
      @calls = saved.size
      @tools_used = saved.pluck('name')
      @results = saved.pluck('result')
    end

    def definitions
      @definitions ||= lookup_definitions + mcp_definitions + write_definitions
    end

    def names = definitions.map(&:name)

    def activity_for(name)
      definitions.find { |definition| definition.name == name.to_s }&.activity || 'Working'
    end

    # RubyLLM tool objects for native tool calling.
    def llm_tools
      definitions.map { |definition| LlmTool.build(definition) { |args| call(definition.name, args) } }
    end

    # The tool list as text, for the opencode CLI engine (no native tool calling).
    def prompt_section
      definitions.map do |definition|
        props = definition.schema[:properties] || {}
        required = Array(definition.schema[:required]).map(&:to_s)
        args = props.map { |key, spec| "#{key}#{'*' if required.include?(key.to_s)}#{" (#{spec[:enum].join('|')})" if spec[:enum]}" }.join(', ')
        "- #{definition.name}(#{args}) — #{definition.description.to_s.first(220)}"
      end.join("\n")
    end

    # Runs one call and returns text for the model. Never raises.
    def call(name, arguments)
      return call_once(name, arguments) unless @execution

      @execution.tool!(call_id, name, arguments || {}, write: WRITE_TOOLS.include?(name)) { call_once(name, arguments) }
    end

    def call_once(name, arguments)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @calls += 1
      return 'Tool budget used up for this message. Answer now from what you already have, and say what you could not check.' if @calls > MAX_CALLS

      definition = definitions.find { |candidate| candidate.name == name.to_s }
      return log(name, started, 'unknown', "No tool named #{name.to_s.first(40)}. Use one of: #{names.join(', ')}.") unless definition

      args = arguments.is_a?(Hash) ? arguments.deep_stringify_keys.compact : {}
      coerced, problems = Mcp::SchemaValidator.call(definition.schema, args)
      return log(name, started, 'invalid', "Invalid arguments: #{problems.first(3).join(' ')}") if problems.any?

      @tools_used << definition.name
      text = case definition.kind
             when :lookup then run_lookup(definition.name, coerced)
             when :mcp then run_mcp(definition.name, coerced)
             when :write then propose(definition.name, coerced)
             end
      log(name, started, 'ok', text)
    rescue Mcp::ToolError => e
      log(name, started, 'error', e.message.to_s.first(400))
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { team_chat_tool: name.to_s.first(40) })
      log(name, started, 'error', 'That lookup failed. Say you could not check it and suggest the page itself.')
    end

    private

    def lookup_definitions
      @lookups.definitions.select { |definition| LOOKUPS.include?(definition.name) }.map do |definition|
        Definition.new(name: definition.name, description: definition.description, kind: :lookup,
          schema: { type: 'object', properties: definition.properties, required: definition.required, additionalProperties: false },
          activity: { 'where_is' => 'Finding the page', 'how_do_i' => 'Looking up how it works', 'search' => 'Searching records',
                      'system_status' => 'Checking system status' }[definition.name])
      end
    end

    def mcp_definitions
      Mcp::Registry.available_to(@token).select(&:read_only).select { |tool| offered?(tool.tool_name) }.map do |tool|
        Definition.new(name: tool.tool_name, description: tool.description, kind: :mcp, schema: tool.input_schema,
          activity: "Checking #{tool.title.to_s.downcase.presence || tool.tool_name.tr('_', ' ')}")
      end
    end

    def write_definitions
      WRITE_TOOLS.select { |name| offered?(name) }.filter_map { |name| Mcp::Registry.find(name) }.select { |tool| Actions.permitted?(@user, tool) }.map do |tool|
        Definition.new(name: tool.tool_name, kind: :write, schema: tool.input_schema, activity: 'Preparing a change for approval',
          description: "PROPOSES a change; nothing happens until a person presses Approve on the card it creates. #{tool.description}")
      end
    end

    def offered?(name) = @only.nil? || @only.include?(name.to_s)

    def run_lookup(name, args)
      result = @lookups.call(name, args)
      result.text.to_s
    end

    def run_mcp(name, args)
      tool = Mcp::Registry.find(name)
      outcome = tool.new(token: @token).call(args)
      AskRupert::Redactor.personal("#{outcome.text}\n#{JSON.generate(with_dollars(outcome.data))}")
    end

    # Adds a ready-made "$214.83" beside every *_cents amount, so models quote dollars instead of converting cents.
    def with_dollars(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, inner), out|
          out[key] = with_dollars(inner)
          name = key.to_s
          out["#{name.delete_suffix('_cents')}_dollars"] = dollars(inner) if name.end_with?('_cents') && inner.is_a?(Numeric)
        end
      when Array then value.map { |inner| with_dollars(inner) }
      else value
      end
    end

    def dollars(cents)
      "#{'-' if cents.negative?}$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', cents.abs / 100.0))}"
    end

    def propose(name, args)
      args = prepare(name, args)
      action = Actions.propose!(@reply, tool: name, arguments: args, proposed_for: @user)
      "Proposed as action #{action['id']}: “#{action['summary']}”. A card with Approve and Dismiss is shown in the room. " \
        'Tell them it is waiting for their approval. Do not say it is done.'
    end

    # Checks what can be checked before a card is shown, so the model can ask
    # again (which person? which task?) instead of the change failing at Approve.
    # The person is pinned by email so Approve assigns exactly who the card names.
    def prepare(name, args)
      args = args.dup
      if args['assignee'].present? && %w[create_task update_task].include?(name)
        person = Mcp::Assignee.resolve(@user, args['assignee'])
        args['assignee'] = person == :nobody ? 'nobody' : person.email
      end
      if name == 'update_task'
        task = Projects::TaskPolicy::Scope.new(@user, Projects::Task).resolve.find_by(id: args['task_id'])
        raise Mcp::ToolError.new("No task ##{args['task_id']} that this person can see. Use list_tasks to find it.", kind: 'not_found') unless task
        raise Mcp::ToolError.new("This person cannot change task ##{task.id}.", kind: 'denied') unless Projects::TaskPolicy.new(@user, task).update?

        args['task_title'] = task.title
      end
      args
    end

    def log(name, started, outcome, text)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      ActivityLogger.log('team_chat_tool', actor: @user,
        details: "tool=#{name.to_s.gsub(/[^\w]/, '?').first(30)}; outcome=#{outcome}; duration_ms=#{ms}; room=#{@room.id}")
      text = text.to_s.first(MAX_RESULT_CHARS)
      @results << text
      text
    end
  end
end
