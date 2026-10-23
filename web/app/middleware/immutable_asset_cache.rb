# frozen_string_literal: true

# Fingerprinted assets (name-<sha256>.ext under the assets prefix) never change:
# a new build gives them a new name. Telling browsers so lets every page after the
# first load its CSS and JavaScript from cache without asking the server again.
class ImmutableAssetCache
  FINGERPRINT = /-[0-9a-f]{40,}\.[a-z0-9]+\z/
  HEADER = 'public, max-age=31536000, immutable'

  def initialize(app, prefix: Rails.application.config.assets.prefix)
    @app = app
    @prefix = "#{prefix.chomp('/')}/"
  end

  def call(env)
    status, headers, body = @app.call(env)
    path = env['PATH_INFO'].to_s
    headers['cache-control'] = HEADER if status == 200 && path.start_with?(@prefix) && path.match?(FINGERPRINT)
    [status, headers, body]
  end
end
