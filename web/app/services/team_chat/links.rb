# frozen_string_literal: true

require 'uri'

module TeamChat
  # Mirrors the chat renderer's link/code syntax. A completed denied link is
  # removed before any partial reply can be saved, not just at finalization.
  module Links
    LINK = %r{\[([^\]\n]{1,120})\]\((/(?!/)[^)\s]*)\)}
    INLINE = /`([^`\n]+)`|\[([^\]\n]{1,120})\]\(([^)\s]*)\)/
    ABSOLUTE = %r{https?://[^\s<>"'`]+}i

    module_function

    def for_user(text, user:)
      text = text.to_s
      return text unless text.match?(INLINE) || text.match?(ABSOLUTE)

      access = LinkAccess.new(user)
      output = +''
      offset = 0
      text.to_enum(:scan, INLINE).each do
        match = Regexp.last_match
        output << plain(text[offset...match.begin(0)], access)
        if match[1]
          output << match[0] # Code is never turned into an active link by the renderer.
        else
          target = authorized_target(match[3], access)
          output << (target ? "[#{match[2]}](#{target})" : plain(match[2], access))
        end
        offset = match.end(0)
      end
      output << plain(text[offset..], access)
    end

    def plain(text, access)
      text.to_s.gsub(ABSOLUTE) do |url|
        trailing = +''
        while url.match?(/[.,;:!?)\]}]\z/)
          trailing.prepend(url[-1])
          url = url[0...-1]
        end
        target = authorized_target(url, access)
        # Unverified absolute addresses remain readable but cannot be auto-linked
        # by the client (including nested URLs inside their query strings).
        label = url.gsub(%r{https?://}i, '').delete('[]\\')
        (target ? "[#{label}](#{target})" : label) + trailing
      end
    end

    def authorized_target(value, access)
      uri = URI.parse(value)
      if uri.absolute?
        return unless trusted_origin?(uri)
      else
        return if uri.host || uri.scheme || !value.start_with?('/') || value.start_with?('//')
      end
      decoded = URI::DEFAULT_PARSER.unescape(uri.path.to_s)
      return unless decoded.start_with?('/') && !decoded.start_with?('//')
      return if decoded.match?(/[\\\x00-\x20\x7f?#]/) || decoded.match?(/%[0-9a-f]{2}/i) || decoded.split('/').intersect?(%w[. ..])

      # Re-encode path bytes so browsers and Rails agree on the checked path.
      path = URI::DEFAULT_PARSER.escape(decoded)
      path += "?#{uri.query}" if uri.query
      path += "##{uri.fragment}" if uri.fragment
      path if access.allowed?(path)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def trusted_origin?(uri)
      return false unless %w[http https].include?(uri.scheme) && uri.userinfo.nil?

      base = URI.parse(ENV.fetch('HOST', ''))
      hosts = [base.host, ENV['RUPERT_INSTANCE_HOSTNAME']].compact.reject(&:blank?)
      hosts.include?(uri.host) && uri.scheme == (base.scheme || 'https') && uri.port == (base.port || 443)
    rescue URI::InvalidURIError
      false
    end

    # Kept for server-generated guide links and existing callers; model output
    # uses for_user so route existence alone never grants link access.
    def real_paths_only(text)
      text.to_s.gsub(LINK) { real?(Regexp.last_match(2)) ? Regexp.last_match(0) : Regexp.last_match(1) }
    end

    def real?(path)
      route = Rails.application.routes.recognize_path(path.split(/[?#]/).first, method: :get)
      route.present? && route[:controller].present? && !route[:controller].start_with?('rails/')
    rescue ActionController::RoutingError, ArgumentError
      false
    end
  end
end
