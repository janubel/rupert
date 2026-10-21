# frozen_string_literal: true

require 'test_helper'

class AskRupertRedactorTest < ActiveSupport::TestCase
  test 'keys, tokens and card-like numbers never reach a model' do
    text = AskRupert::Redactor.clean("my key sk-abcdefghijklmnopqrstuvwx and rupert_#{'a' * 43} card 4242 4242 4242 4242 Bearer abcdefghijklmnopqrstuv")
    assert_no_match(/sk-abc|rupert_a|4242|Bearer abc/, text)
  end

  test 'personal details are removed from tool results' do
    text = AskRupert::Redactor.personal('Call 555-123-4567 or write a.b+c@example.com')
    assert_equal 'Call [phone] or write [email]', text
  end

  test 'control characters are stripped and newlines kept' do
    assert_equal "a\nb", AskRupert::Redactor.clean("a\u0000\nb\u0007")
  end
end
