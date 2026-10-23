# frozen_string_literal: true

require 'test_helper'

class CssSanitizerDependencyTest < ActiveSupport::TestCase
  test 'malformed CSS URLs cannot conceal a forbidden declaration from the sanitizer' do
    # GHSA-pq4g-8rxf-4g29: browsers end the bad URL after the escaped
    # backslash; the sanitizer must see and reject the following declaration.
    css = 'width:calc(url(x"' + (92.chr * 2) + '));position:fixed;x:))'
    sanitized = Rails::HTML5::SafeListSanitizer.new.sanitize_css(css)
    assert_no_match(/position\s*:/i, sanitized)
    assert_includes Rails::HTML5::SafeListSanitizer.new.sanitize_css('color: red; width: 10px'), 'color:red'
  end
end
