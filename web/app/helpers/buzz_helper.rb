# frozen_string_literal: true

module BuzzHelper
  # A status pill for the Buzz row in Settings: nil means "not checked yet".
  def buzz_status_pill(value, yes_text, no_text)
    return tag.span('Not checked', class: 'pill-taupe') if value.nil?

    tag.span(value ? yes_text : no_text, class: value ? 'pill-fern' : 'pill-rose')
  end
end
