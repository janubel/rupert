# frozen_string_literal: true

# Request throttling. Limits are per minute unless noted and are deliberately
# generous for people and tight for scripts: a shop of a few staff never hits
# them, a credential-stuffing or webhook-flooding script does. The password
# login also has a database-backed lockout (LoginThrottle); this layer stops
# the flood before it reaches the database.
#
# Store: Rails.cache (file store on SER8, single host). Tests use an isolated
# memory store (config/environments/test.rb).
class Rack::Attack
  SENSITIVE_SETTINGS = %r{\A/settings/(env|env_preview|env_import|env_export|backup|restore)}

  # Health checks are hit by the proxy and the host watcher; never throttle them.
  safelist('health checks') { |req| req.path.start_with?('/up') }

  throttle('login/ip', limit: 30, period: 1.minute) { |req| req.ip if req.post? && req.path == '/login' }
  throttle('login/email', limit: 10, period: 1.minute) do |req|
    req.params['email'].to_s.strip.downcase.presence if req.post? && req.path == '/login'
  end
  throttle('signup/ip', limit: 5, period: 1.hour) { |req| req.ip if req.post? && req.path == '/signup' }
  throttle('google-oauth/ip', limit: 20, period: 1.minute) { |req| req.ip if req.path.start_with?('/auth/google') }

  # Settings secrets: env preview/import/export, backup download, restore.
  throttle('settings-secrets/ip', limit: 10, period: 1.minute) { |req| req.ip if req.path.match?(SENSITIVE_SETTINGS) }

  # Inbound webhooks (Shopify, Authorize.net). Shopify bursts legitimately
  # after an outage, so the cap is high; HMAC verification is the real gate.
  throttle('webhooks/ip', limit: 300, period: 1.minute) do |req|
    req.ip if req.post? && (req.path.start_with?('/api/webhooks/') || req.path.start_with?('/webhooks/'))
  end

  # Bearer API: per token when present (hashed, never the secret), per IP otherwise.
  throttle('api/token', limit: 300, period: 1.minute) do |req|
    next unless req.path.start_with?('/api/v1/')

    token = req.get_header('HTTP_AUTHORIZATION').to_s[/\ABearer (\S+)\z/i, 1]
    token ? Digest::SHA256.hexdigest(token) : nil
  end
  throttle('api/ip', limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?('/api/v1/') && req.get_header('HTTP_AUTHORIZATION').blank?
  end
  # MCP endpoint for AI assistants: its own per-token bucket (hashed secret),
  # separate from the REST API so a chatty assistant cannot starve an
  # integration, plus a tight per-IP cap for calls without a token.
  throttle('mcp/token', limit: 120, period: 1.minute) do |req|
    next unless req.path == '/mcp'

    token = req.get_header('HTTP_AUTHORIZATION').to_s[/\ABearer (\S+)\z/i, 1]
    token ? Digest::SHA256.hexdigest(token) : nil
  end
  throttle('mcp/ip', limit: 30, period: 1.minute) do |req|
    req.ip if req.path == '/mcp' && req.get_header('HTTP_AUTHORIZATION').blank?
  end
  # Uploads: the inbox keeps encrypted originals, so sending files has its own,
  # tighter buckets on top of the general API and per-IP ceilings.
  throttle('uploads-api/token', limit: 30, period: 1.minute) do |req|
    next unless req.post? && req.path == '/api/v1/uploads'

    token = req.get_header('HTTP_AUTHORIZATION').to_s[/\ABearer (\S+)\z/i, 1]
    token ? Digest::SHA256.hexdigest(token) : req.ip
  end
  throttle('uploads-web/ip', limit: 30, period: 1.minute) { |req| req.ip if req.post? && req.path == '/uploads' }
  throttle('employee-login/ip', limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == '/api/v1/employee/session'
  end

  # Public, token-gated warehouse portal and customer display.
  throttle('public-portal/ip', limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?('/w/') || req.path.start_with?('/customer_display')
  end

  # Everything else: a broad ceiling that only a script reaches.
  throttle('all/ip', limit: 600, period: 1.minute) { |req| req.ip unless req.path.start_with?('/api/assets') }

  self.throttled_responder = lambda do |request|
    match = request.env['rack.attack.match_data'] || {}
    retry_after = (match[:period].to_i - (Time.now.to_i % [match[:period].to_i, 1].max)).clamp(1, 3600)
    headers = { 'Content-Type' => 'application/json', 'Retry-After' => retry_after.to_s, 'Cache-Control' => 'no-store' }
    [429, headers, [{ error: { code: 'rate_limited', message: "Too many requests. Try again in #{retry_after} seconds." } }.to_json]]
  end
end

ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn("[rack-attack] throttled #{req.env['rack.attack.matched']} #{req.request_method} #{req.path} from #{req.ip}")
end
