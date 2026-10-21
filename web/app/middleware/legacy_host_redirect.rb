# frozen_string_literal: true

require 'set'
require 'uri'

# Sends retired hostnames (RUPERT_LEGACY_HOSTS, comma-separated) to the
# canonical origin in HOST, keeping the path and query. GET and HEAD get a 301
# so bookmarks update; other methods get a 308 so a form post or API call is
# repeated as-is instead of turning into a GET. Health checks (/up...) are
# answered on any host so monitors and the deployer keep working. Runs before
# host authorization, so retired names need not stay in ADDITIONAL_HOSTS.
class LegacyHostRedirect
  def initialize(app, legacy: ENV.fetch('RUPERT_LEGACY_HOSTS', ''), canonical: ENV.fetch('HOST', ''))
    @app = app
    @origin = origin_of(canonical)
    @legacy = legacy.to_s.split(',').map { |host| host.strip.downcase }.reject(&:empty?).to_set
    @legacy.delete(URI(@origin).host) if @origin
  end

  def call(env)
    request = Rack::Request.new(env)
    return @app.call(env) unless redirect?(request)

    status = request.get? || request.head? ? 301 : 308
    [status, { 'location' => "#{@origin}#{request.fullpath}", 'content-type' => 'text/plain; charset=utf-8' },
     ["Rupert moved to #{@origin}\n"]]
  end

  private

  def redirect?(request)
    @origin && @legacy.include?(request.host.to_s.downcase) && !request.path.start_with?('/up')
  end

  def origin_of(value)
    uri = URI(value.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.port == uri.default_port ? "#{uri.scheme}://#{uri.host}" : "#{uri.scheme}://#{uri.host}:#{uri.port}"
  rescue URI::InvalidURIError
    nil
  end
end
