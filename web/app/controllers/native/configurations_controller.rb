# frozen_string_literal: true

module Native
  # GET /native/ios/path-configuration.json: navigation rules for the Rupert iPhone app
  # (Hotwire Native). Served from here so rules change with a deploy, not an App Store release;
  # the app also bundles a copy for its first launch and for offline starts.
  class ConfigurationsController < ApplicationController
    skip_before_action :require_login

    RULES = [
      { patterns: ['.*'], properties: { context: 'default', pull_to_refresh_enabled: true } },
      # Forms open as sheets over the page they belong to.
      { patterns: ['/new$', '/new\\?', '/edit$', '/edit\\?'], properties: { context: 'modal', pull_to_refresh_enabled: false } },
      # Signing in or out replaces the whole stack instead of piling pages behind it.
      { patterns: ['^/login$', '^/logout$'], properties: { context: 'default', presentation: 'replace_root', pull_to_refresh_enabled: false } },
      # Pages that poll or scroll their own content keep pull-to-refresh out of the way.
      { patterns: ['^/chat', '^/ask_rupert', '^/sales/pos', '^/pos'], properties: { pull_to_refresh_enabled: false } }
    ].freeze

    def ios
      expires_in 5.minutes, public: true
      render json: { settings: {}, rules: RULES }
    end
  end
end
