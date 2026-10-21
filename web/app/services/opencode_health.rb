# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# Checks the opencode integration the @rupert Buzz agent depends on, without
# spending tokens:
#   1. GET <provider>/models with the configured key. The key is validated by
#      the response (401 = rejected, with the vendor's code such as
#      api_key_expired) and the provider's own catalog tells whether the
#      configured model is still offered.
#   2. GET https://opencode.ai/zen/v1/models for the live list of free models
#      (ids ending in -free). The list changes, so it is read on every check and
#      never hard-coded.
#   3. Optionally (OPENCODE_HEALTH_PROBE=1) one 1-token chat call to a free model
#      to see IP-level rate limits before the agent hits them.
# opencode documents no balance or usage API (only the web console), so none is
# queried; token counts come from the agent's own runs (OpencodeUsage).
#
# Configuration (environment; this is instance-wide, not per workspace):
#   OPENCODE_API_KEY    the key; else read from OPENCODE_AUTH_FILE
#   OPENCODE_AUTH_FILE  opencode auth.json (default ~/.local/share/opencode/auth.json)
#   OPENCODE_PROVIDER   go (default, the agent's OpenCode Go key) or zen
#   OPENCODE_MODEL      the model id the agent uses (default deepseek-v4-flash)
# The key is only ever sent as a bearer token to opencode.ai; it is never
# logged, stored or returned.
class OpencodeHealth
  ZEN_BASE = 'https://opencode.ai/zen/v1'
  GO_BASE = 'https://opencode.ai/zen/go/v1'
  DEFAULT_MODEL = 'deepseek-v4-flash'
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  RETENTION = 90.days
  ERROR_CODE_FORMAT = /\A[a-z0-9_.-]{1,60}\z/

  Response = Struct.new(:status, :body, :latency_ms, :retry_after, :failure, keyword_init: true)

  class << self
    def check!(trigger: 'scheduled') = new.check!(trigger: trigger)
  end

  def provider = ENV.fetch('OPENCODE_PROVIDER', 'go').downcase == 'zen' ? 'zen' : 'go'
  def model = ENV['OPENCODE_MODEL'].presence || DEFAULT_MODEL
  def base = provider == 'zen' ? ZEN_BASE : GO_BASE
  def probe? = ENV['OPENCODE_HEALTH_PROBE'] == '1'

  def api_key
    ENV['OPENCODE_API_KEY'].presence || key_from_auth_file
  end

  def check!(trigger: 'scheduled')
    started = Time.current
    attrs = { triggered_by: trigger, configured_model: model, checked_at: started }
    free = check_free_models(attrs)
    check_provider(attrs, free)
    attrs[:status] = status_for(attrs)
    AiHealthCheck.create!(attrs)
  ensure
    AiHealthCheck.where(checked_at: ...(RETENTION.ago)).delete_all
  end

  private

  def key_from_auth_file
    path = ENV['OPENCODE_AUTH_FILE'].presence || File.join(Dir.home, '.local/share/opencode/auth.json')
    auth = JSON.parse(File.read(path))
    entry = auth["opencode-#{provider}"] || auth['opencode'] || auth['opencode-go']
    entry.is_a?(Hash) ? entry['key'].presence : nil
  rescue StandardError
    nil
  end

  # Public list: which models are free right now.
  def check_free_models(attrs)
    response = get("#{ZEN_BASE}/models")
    attrs[:catalog_latency_ms] = response.latency_ms
    note_failure(attrs, response, scope: :catalog)
    ids = model_ids(response) or return nil
    free = ids.select { |id| id.end_with?('-free') }.sort
    attrs[:free_models] = free
    attrs[:free_model_count] = free.size
    ids
  end

  # The provider the agent uses: key validity and model availability.
  def check_provider(attrs, zen_ids)
    key = api_key
    attrs[:model_state] = 'unknown'
    if key.nil?
      attrs[:key_state] = 'missing'
      attrs[:model_state] = availability(zen_ids) if provider == 'zen'
      return
    end

    response = get("#{base}/models", key: key)
    attrs[:latency_ms] = response.latency_ms
    attrs[:http_status] = response.status
    if response.status == 200
      attrs[:key_state] = 'valid'
      ids = model_ids(response)
      attrs[:catalog_size] = ids&.size
      attrs[:model_state] = availability(ids)
    else
      attrs[:key_state] = key_state_for(response)
      note_failure(attrs, response, scope: :provider)
    end
    probe(attrs, key)
  end

  def probe(attrs, key)
    return unless probe? && attrs[:free_models].present?

    body = { model: attrs[:free_models].first, messages: [{ role: 'user', content: 'ping' }], max_tokens: 1 }
    response = post("#{ZEN_BASE}/chat/completions", body, key: key)
    note_failure(attrs, response, scope: :probe) unless response.status == 200
  end

  def availability(ids)
    return 'unknown' if ids.nil?

    ids.include?(model.sub(%r{\Aopencode(-go)?/}, '')) ? 'available' : 'missing'
  end

  def model_ids(response)
    return unless response.status == 200

    list = JSON.parse(response.body.to_s)['data']
    list.is_a?(Array) ? list.filter_map { |entry| entry['id'] if entry.is_a?(Hash) } : nil
  rescue JSON::ParserError, TypeError
    nil
  end

  def key_state_for(response)
    return 'unchecked' unless [401, 403].include?(response.status)

    error_code(response).to_s.include?('expired') ? 'expired' : 'invalid'
  end

  # A rate limit is always flagged. The provider's failure is the one that
  # explains the key state, so it wins; the catalog and probe only fill in when
  # nothing else has been recorded.
  def note_failure(attrs, response, scope:)
    return if response.failure.nil? && response.status == 200

    if response.status == 429
      attrs[:rate_limited] = true
      attrs[:retry_after_seconds] ||= response.retry_after
    end
    return if attrs[:error_type] && scope != :provider

    attrs[:error_type] = error_type(response)
    attrs[:error_code] = error_code(response)
    attrs[:http_status] ||= response.status
  end

  def error_type(response)
    return response.failure if response.failure

    case response.status
    when 401, 403 then 'auth'
    when 429 then 'rate_limited'
    when 500.. then 'server_error'
    else 'unexpected_response'
    end
  end

  # The vendor's machine code (api_key_expired, ...), only when it looks like
  # one: free text from a response is never kept.
  def error_code(response)
    code = JSON.parse(response.body.to_s).dig('error', 'code')
    code.to_s.match?(ERROR_CODE_FORMAT) ? code.to_s : nil
  rescue JSON::ParserError, TypeError
    nil
  end

  def status_for(attrs)
    return 'error' if %w[invalid expired].include?(attrs[:key_state])
    return 'error' if attrs[:key_state] == 'unchecked' && !attrs[:rate_limited]
    return 'not_configured' if attrs[:key_state] == 'missing'
    return 'warning' if attrs[:rate_limited] || attrs[:error_type] || attrs[:model_state] == 'missing'

    attrs[:free_model_count].zero? ? 'warning' : 'ok'
  end

  def get(url, key: nil) = request(Net::HTTP::Get, url, nil, key)
  def post(url, body, key: nil) = request(Net::HTTP::Post, url, body, key)

  def request(klass, url, body, key)
    uri = URI(url)
    req = klass.new(uri)
    req['User-Agent'] = "Rupert-AI-Health/#{BuildInfo.current.short_revision}"
    req['x-opencode-session'] = 'rupert-ai-health'
    req['Authorization'] = "Bearer #{key}" if key
    if body
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    res = http.start { |conn| conn.request(req) }
    Response.new(status: res.code.to_i, body: res.body, latency_ms: elapsed_ms(started), retry_after: res['retry-after']&.to_i)
  rescue Net::OpenTimeout, Net::ReadTimeout
    Response.new(status: nil, latency_ms: elapsed_ms(started), failure: 'timeout')
  rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError
    Response.new(status: nil, latency_ms: elapsed_ms(started), failure: 'network')
  end

  def elapsed_ms(started)
    started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round : nil
  end
end
