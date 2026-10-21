# frozen_string_literal: true

# Model Context Protocol endpoint (Streamable HTTP transport, plain JSON
# responses, no SSE, no server-side session). External AI assistants call
# POST /mcp with one JSON-RPC 2.0 message and the same bearer token the REST
# API uses; the token's store, scopes and owner permissions decide what they
# may see. Protocol handling lives in Mcp::Server. See docs/mcp.md.
class McpController < ActionController::API
  MAX_BODY_BYTES = 256.kilobytes

  around_action :isolated_context
  before_action :validate_origin
  before_action :authenticate_token, only: :create

  def create
    return render_error(413, Mcp::Server::INVALID_REQUEST, 'Request body is too large (limit 256 KB).') if request.content_length.to_i > MAX_BODY_BYTES
    return render_error(400, Mcp::Server::INVALID_REQUEST, "Unsupported MCP-Protocol-Version. Supported: #{Mcp::Server::PROTOCOL_VERSIONS.join(', ')}.") unless supported_protocol_header?

    message = parse_body
    return if performed?

    payload, status = Mcp::Server.new(token: @api_token).handle(message)
    payload ? render(json: payload, status: status) : head(status)
  end

  # Streamable HTTP lets a server refuse the optional GET event stream and
  # session deletion; this server is stateless and answers in the POST.
  def method_not_allowed
    response.headers['Allow'] = 'POST'
    render_error(405, Mcp::Server::INVALID_REQUEST, 'Method not allowed. Send JSON-RPC requests with POST /mcp.')
  end

  private

  def isolated_context
    Current.reset
    response.headers['Cache-Control'] = 'no-store'
    yield
  ensure
    Current.reset
  end

  # DNS-rebinding protection required by the MCP transport spec: a browser
  # page on another site must not drive this endpoint. Non-browser clients
  # send no Origin header and are unaffected.
  def validate_origin
    origin = request.headers['Origin'].to_s
    return if origin.blank? || allowed_origin?(origin)

    render_error(403, Mcp::Server::INVALID_REQUEST, 'Origin not allowed.')
  end

  def allowed_origin?(origin)
    uri = URI.parse(origin)
    return true if uri.host.present? && uri.host.casecmp?(request.host)

    extra = ENV.fetch('MCP_ALLOWED_ORIGINS', '').split(',').map { |value| value.strip.chomp('/') }.reject(&:blank?)
    extra.include?(origin.chomp('/'))
  rescue URI::InvalidURIError
    false
  end

  def authenticate_token
    secret = request.headers['Authorization'].to_s.match(/\ABearer (\S+)\z/i)&.captures&.first
    @api_token = ApiAccessToken.authenticate(secret)
    unless @api_token
      response.headers['WWW-Authenticate'] = 'Bearer realm="Rupert MCP"'
      return render_error(401, -32_001, 'A valid Rupert API bearer token is required (Authorization: Bearer rupert_...).')
    end

    Current.user = @api_token.user
    Current.tenant = @api_token.tenant
    render_error(403, -32_001, 'Token owner does not belong to this store.') if Current.user.tenant_id != Current.tenant.id
  end

  def supported_protocol_header?
    version = request.headers['MCP-Protocol-Version']
    version.blank? || Mcp::Server::PROTOCOL_VERSIONS.include?(version)
  end

  def parse_body
    body = request.raw_post.to_s
    JSON.parse(body)
  rescue JSON::ParserError
    render_error(400, Mcp::Server::PARSE_ERROR, 'Parse error: the request body is not valid JSON.')
    nil
  end

  def render_error(status, code, message)
    render json: Mcp::Server.error_response(nil, code, message), status: status
  end
end
