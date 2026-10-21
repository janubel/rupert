# frozen_string_literal: true

require 'test_helper'

class FeedbackSanitizerTest < ActiveSupport::TestCase
  test 'hides values of keys the request log filters, in query strings and JSON' do
    text = 'GET /x?password=hunter2&page=2 {"api_token":"abc123","name":"Pat"} authorization: abcdef secret=1'
    out = FeedbackSanitizer.scrub_text(text)
    assert_includes out, 'password=[FILTERED]'
    assert_includes out, 'page=2'
    assert_includes out, '"api_token":[FILTERED]'
    assert_includes out, '"name":"Pat"'
    assert_includes out, 'secret=[FILTERED]'
    assert_not_includes out, 'hunter2'
    assert_not_includes out, 'abc123'
  end

  test 'hides bearer headers and Rupert tokens wherever they appear' do
    token = "rupert_#{'a' * 43}"
    out = FeedbackSanitizer.scrub_text("curl -H 'Bearer abcdefgh12345' #{token}")
    assert_not_includes out, token
    assert_not_includes out, 'abcdefgh12345'
  end

  test 'sql literals become placeholders' do
    sql = "SELECT * FROM users WHERE email = 'pat@example.com' AND id = 42 AND total > 3.5 LIMIT 1 -- col1"
    out = FeedbackSanitizer.scrub_sql(sql)
    assert_includes out, "email = '?'"
    assert_includes out, 'id = ?'
    assert_includes out, 'total > ?'
    assert_includes out, 'col1'
    assert_not_includes out, 'pat@example.com'
  end

  test 'urls keep the path and filtered query values are hidden, fragment dropped' do
    out = FeedbackSanitizer.scrub_url('https://x.example.com/inventory?q=tea&token=abc#frag')
    assert_equal '/inventory?q=tea&token=%5BFILTERED%5D', out
    assert_nil FeedbackSanitizer.scrub_url('http://[bad')
  end

  test 'invalid bytes do not raise' do
    assert_nothing_raised { FeedbackSanitizer.scrub_text("bad \xFF byte password=x") }
  end
end
