# frozen_string_literal: true

require 'uri'

# Public connection info for the team's Buzz chat, for the Buzz card people open
# from the header: what the relay and channel are, where each platform's client
# comes from, and the links that open the chat or add the workspace.
#
# Only public values are handled here (relay URL, channel id, the agent's npub).
# Each person signs in to Buzz with their own identity in their own client; the
# agent's private key never reaches this class' output.
#
# Everything a link needs is configurable in Settings (EnvStore) with defaults
# taken from the Buzz project itself (github.com/block/buzz):
#
#   BUZZ_CHAT_LINK_TEMPLATE     default buzz://channel/{channel}
#   BUZZ_CONNECT_LINK_TEMPLATE  default buzz://add-community?relay={relay}&name={name}
#   BUZZ_DOWNLOAD_MACOS / _WINDOWS / _LINUX / _IOS / _ANDROID, BUZZ_WEB_URL
#
# Templates accept {relay}, {channel} and {name}; values are URL-encoded.
# Links are only ever built from the buzz: scheme or https, so a setting cannot
# turn a button into a script link.
class BuzzConnect
  RELEASES_URL = 'https://github.com/block/buzz/releases/latest'
  DEFAULT_CHAT_TEMPLATE = 'buzz://channel/{channel}'
  DEFAULT_CONNECT_TEMPLATE = 'buzz://add-community?relay={relay}&name={name}'
  CHANNEL_UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  LINK_SCHEMES = %w[buzz https].freeze

  Platform = Struct.new(:key, :label, :env_key, :default, :note, :url, keyword_init: true) do
    def available? = url.present?
  end

  PLATFORMS = [
    { key: 'macos', label: 'macOS', env_key: 'BUZZ_DOWNLOAD_MACOS', default: RELEASES_URL,
      note: 'Disk image (.dmg) for Apple silicon and Intel Macs.' },
    { key: 'windows', label: 'Windows', env_key: 'BUZZ_DOWNLOAD_WINDOWS', default: RELEASES_URL,
      note: 'Installer (.exe). It is not code-signed, so Windows may warn on first launch: More info, then Run anyway.' },
    { key: 'linux', label: 'Linux', env_key: 'BUZZ_DOWNLOAD_LINUX', default: RELEASES_URL,
      note: 'AppImage or .deb for x86-64.' },
    { key: 'ios', label: 'iPhone & iPad', env_key: 'BUZZ_DOWNLOAD_IOS', default: nil,
      note: 'The Buzz mobile app is still in development and has no public App Store listing yet.' },
    { key: 'android', label: 'Android', env_key: 'BUZZ_DOWNLOAD_ANDROID', default: nil,
      note: 'The Buzz mobile app is still in development and has no public Play Store listing yet.' },
    { key: 'web', label: 'Web', env_key: 'BUZZ_WEB_URL', default: nil,
      note: 'Buzz has no hosted web chat client yet; use the desktop app.' }
  ].freeze

  class << self
    def relay_url
      value = BuzzAgent.relay_url
      uri = URI.parse(value)
      return nil unless %w[ws wss].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?

      value
    rescue URI::InvalidURIError
      nil
    end

    def channel_id = BuzzAgent.channel_id.presence

    def relay_configured? = relay_url.present?

    # ready: relay and channel set. relay_only: people can add the workspace but
    # there is no channel to open. unconfigured: nothing to connect to yet.
    def state
      return :unconfigured unless relay_configured?

      channel_id ? :ready : :relay_only
    end

    def ready? = state == :ready

    def channel_looks_valid? = channel_id.nil? || channel_id.match?(CHANNEL_UUID)

    # Opens the team channel (or, with no channel, adds the workspace).
    def chat_url
      case state
      when :ready then expand(setting('BUZZ_CHAT_LINK_TEMPLATE', DEFAULT_CHAT_TEMPLATE))
      when :relay_only then connect_url
      end
    end

    # Adds this workspace to a Buzz app. Also what the QR code carries.
    def connect_url
      return nil unless relay_configured?

      expand(setting('BUZZ_CONNECT_LINK_TEMPLATE', DEFAULT_CONNECT_TEMPLATE))
    end

    def platforms
      PLATFORMS.map do |spec|
        Platform.new(**spec, url: safe_link(setting(spec[:env_key], spec[:default]), %w[https]))
      end
    end

    def workspace_name
      Current.tenant&.name.presence || 'Rupert'
    end

    def agent_npub = BuzzAgent.agent_npub

    private

    def setting(key, default)
      EnvStore.fetch(key, '').to_s.strip.presence || default
    end

    def expand(template)
      values = { 'relay' => relay_url, 'channel' => channel_id, 'name' => workspace_name }
      filled = template.to_s.gsub(/\{(relay|channel|name)\}/) { ERB::Util.url_encode(values[Regexp.last_match(1)].to_s) }
      safe_link(filled, LINK_SCHEMES)
    end

    # Returns the link only when it is an absolute URL on an allowed scheme.
    def safe_link(value, schemes)
      return nil if value.blank?

      uri = URI.parse(value.to_s.strip)
      return nil unless schemes.include?(uri.scheme&.downcase)
      return nil if uri.scheme.casecmp?('https') && (uri.host.blank? || uri.userinfo)

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end
  end
end
