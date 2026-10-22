# frozen_string_literal: true

module TeamChat
  # Small models sometimes invent page addresses ("[Alerts](/inventory/alerts)").
  # A reply may only link pages Rupert really has; any other link becomes plain text.
  module Links
    LINK = %r{\[([^\]\n]{1,120})\]\((/(?!/)[^)\s]*)\)}

    module_function

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
