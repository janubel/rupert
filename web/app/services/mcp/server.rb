# frozen_string_literal: true

module Mcp
  # Model Context Protocol server core: JSON-RPC 2.0 dispatch for one
  # authenticated API token. Stateless — every request carries its bearer
  # token, so no MCP session is kept. Transport (HTTP, auth, Origin) lives in
  # McpController.
  #
  # #handle returns a JSON-RPC response hash, or nil for notifications and
  # client responses (the controller answers those with 202 Accepted).
  class Server
    PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
    LATEST_PROTOCOL = PROTOCOL_VERSIONS.first
    MAX_RESULT_BYTES = 200_000

    PARSE_ERROR = -32_700
    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602
    INTERNAL_ERROR = -32_603
    # Unknown names share one struggle row so arbitrary names cannot add rows.
    UNKNOWN_TOOL = '(unknown tool)'

    INSTRUCTIONS = 'Rupert is a retail ERP for one store. Call get_workspace_info first. Sales sources are reported ' \
                   'separately and must not be added together; null means unknown, not zero; money is integer cents. ' \
                   'Only create_task and submit_feedback write anything, and nothing writes to Shopify, Square or ' \
                   'C-Trax. Please call submit_feedback whenever a tool confuses you, fails, or you finish a task — ' \
                   'the owner reads it to improve Rupert. See resource rupert://guide/getting-started.'

    attr_reader :token

    def initialize(token:)
      @token = token
    end

    def self.error_response(id, code, message)
      { jsonrpc: '2.0', id: id, error: { code: code, message: message } }
    end

    # Returns [response_or_nil, http_status].
    def handle(message)
      unless message.is_a?(Hash) && message['jsonrpc'] == '2.0'
        return [self.class.error_response(nil, INVALID_REQUEST, 'Invalid Request: send one JSON-RPC 2.0 object with "jsonrpc": "2.0". Batches are not supported.'), 400]
      end

      id = message['id']
      method = message['method']
      if method.nil?
        # A client response to a server request (we never send any): acknowledge.
        return [nil, 202] if message.key?('result') || message.key?('error')

        return [self.class.error_response(valid_id?(id) ? id : nil, INVALID_REQUEST, 'Invalid Request: "method" is required.'), 400]
      end
      return [self.class.error_response(nil, INVALID_REQUEST, 'Invalid Request: "method" must be a string.'), 400] unless method.is_a?(String)
      return [nil, 202] unless message.key?('id') # notification, e.g. notifications/initialized
      return [self.class.error_response(nil, INVALID_REQUEST, 'Invalid Request: "id" must be a string or integer.'), 400] unless valid_id?(id)

      params = message['params']
      return [error(id, INVALID_PARAMS, 'Invalid params: "params" must be an object.'), 200] unless params.nil? || params.is_a?(Hash)

      [dispatch(id, method, params || {}), 200]
    end

    private

    def valid_id?(id)
      id.is_a?(String) || id.is_a?(Integer)
    end

    def dispatch(id, method, params)
      case method
      when 'initialize' then success(id, initialize_result(params))
      when 'ping' then success(id, {})
      when 'tools/list' then success(id, { tools: Registry.available_to(token).map(&:definition) })
      when 'tools/call' then call_tool(id, params)
      when 'resources/list' then success(id, { resources: Resources.list })
      when 'resources/templates/list' then success(id, { resourceTemplates: [] })
      when 'resources/read' then read_resource(id, params)
      else error(id, METHOD_NOT_FOUND, "Method not found: #{method.to_s.first(80)}. Supported: initialize, ping, tools/list, tools/call, resources/list, resources/read.")
      end
    end

    def initialize_result(params)
      requested = params['protocolVersion']
      {
        protocolVersion: PROTOCOL_VERSIONS.include?(requested) ? requested : LATEST_PROTOCOL,
        capabilities: { tools: { listChanged: false }, resources: { listChanged: false, subscribe: false } },
        serverInfo: { name: 'rupert', title: 'Rupert retail ERP', version: BuildInfo.current.short_revision },
        instructions: INSTRUCTIONS
      }
    end

    def read_resource(id, params)
      uri = params['uri']
      return error(id, INVALID_PARAMS, 'Invalid params: "uri" is required.') unless uri.is_a?(String)

      text = Resources.read(uri, token)
      return error(id, -32_002, "Resource not found: #{uri.first(200)}") unless text

      success(id, { contents: [{ uri: uri, mimeType: 'text/markdown', text: text }] })
    end

    def call_tool(id, params)
      name = params['name']
      arguments = params['arguments'] || {}
      return error(id, INVALID_PARAMS, 'Invalid params: "name" (the tool name) is required.') unless name.is_a?(String) && name.present?
      return error(id, INVALID_PARAMS, 'Invalid params: "arguments" must be an object.') unless arguments.is_a?(Hash)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tool = Registry.find(name)
      unless tool
        AgentToolIssue.record!(tool_name: UNKNOWN_TOOL, error_kind: 'unknown_tool', message: "Requested #{name.first(80)}", token: token)
        record(UNKNOWN_TOOL, 'unknown_tool', started)
        return error(id, INVALID_PARAMS, "Unknown tool: #{name.first(80)}. Call tools/list to see the tools this token can use.")
      end
      unless tool.available_to?(token)
        message = "This token is not allowed to use #{tool.tool_name}. It needs the #{tool.scope} scope" \
                  "#{" and the owner's #{tool.permission} permission" if tool.permission}. Ask the workspace owner to issue a " \
                  'token with that scope (Rupert → API access), or use another tool from tools/list.'
        return tool_failure(id, tool.tool_name, 'denied', message, started)
      end

      coerced, problems = SchemaValidator.call(tool.input_schema, arguments)
      if problems.any?
        return tool_failure(id, tool.tool_name, 'invalid_arguments', "Invalid arguments for #{tool.tool_name}: #{problems.first(5).join(' ')}", started)
      end

      outcome = tool.new(token: token).call(coerced)
      record(tool.tool_name, 'ok', started)
      success(id, tool_result(outcome))
    rescue ToolError => e
      tool_failure(id, tool.tool_name, e.kind, e.message, started)
    rescue ActiveRecord::RecordNotFound
      tool_failure(id, tool.tool_name, 'not_found', 'The record you asked for does not exist in this workspace.', started)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { mcp_tool: tool&.tool_name })
      tool_failure(id, tool&.tool_name || name, 'internal_error',
        'Rupert could not complete this tool call because of an internal error. It has been logged for the owner. ' \
        'Try again later or with different arguments, and consider reporting it with submit_feedback.', started)
    end

    def tool_result(outcome)
      json = JSON.generate(outcome.data)
      if json.bytesize > MAX_RESULT_BYTES
        note = 'The result was too large to return. Use a narrower date range, filters, or a smaller per_page.'
        return { content: [{ type: 'text', text: note }], isError: true }
      end

      { content: [{ type: 'text', text: outcome.text.to_s }, { type: 'text', text: json }], structuredContent: outcome.data, isError: false }
    end

    def tool_failure(id, tool_name, kind, message, started)
      kind = 'tool_error' unless AgentToolIssue::ERROR_KINDS.key?(kind)
      AgentToolIssue.record!(tool_name: tool_name, error_kind: kind, message: message, token: token)
      record(tool_name, kind, started)
      success(id, { content: [{ type: 'text', text: message }], isError: true })
    end

    # Audit trail: tool, token id, outcome and duration — never arguments or results.
    def record(tool_name, outcome, started)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      name = tool_name.to_s.gsub(/[^\w.:()-]/, '?').first(80)
      ActivityLogger.log('mcp_tool_call', subject: token, details: "tool=#{name}; token_id=#{token.id}; outcome=#{outcome}; duration_ms=#{ms}")
      OpsLog.event('mcp_tool_call', level: outcome == 'ok' ? :info : :warn, tool: name, token_id: token.id, tenant_id: token.try(:tenant_id),
        outcome: outcome, duration_ms: ms, persist: outcome == 'internal_error')
    end

    def success(id, result)
      { jsonrpc: '2.0', id: id, result: result }
    end

    def error(id, code, message)
      self.class.error_response(id, code, message)
    end
  end
end
