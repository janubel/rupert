# frozen_string_literal: true

require 'test_helper'

# Views a bot builds for the side panel: only clean data, with unchecked figures counted.
class TeamChatViewsTest < ActiveSupport::TestCase
  def build(args, known = '') = TeamChat::Views.build(args.deep_stringify_keys, known_text: known)

  test 'a table keeps its columns and rows and counts figures that are not in the tool results' do
    view = build({ title: 'Stores today', kind: 'table', columns: %w[Store Net], rows: [['SwipeSimple', '$837.50'], ['C-Trax', 110.65], ['Other', '$999.00']] },
      '{"value":"837.5"} {"value":"110.65"}')
    assert_equal %w[Store Net], view['columns']
    assert_equal 3, view['rows'].size
    assert_equal 1, view['unchecked'], '$999.00 is not in the tool results'
  end

  test 'a chart needs numbers after the label column' do
    assert build({ title: 'Week', kind: 'bar_chart', columns: %w[Day Sales], rows: [['Mon', 10], ['Tue', '$20.00']] })
    error = assert_raises(ArgumentError) { build({ title: 'Week', kind: 'line_chart', columns: %w[Day Note], rows: [%w[Mon quiet]] }) }
    assert_match(/needs numbers/, error.message)
  end

  test 'html is cleaned of scripts, styles, links and outside images' do
    view = build({ title: 'Note', kind: 'html', html: '<h2>Close</h2><script>alert(1)</script><style>body{}</style><img src="https://x.test/p.gif"><a href="https://x.test">x</a><table><tr><td colspan="2" onclick="go()">ok</td></tr></table>' })
    html = view['html']
    assert_includes html, '<h2>Close</h2>'
    assert_includes html, '<td colspan="2">ok</td>'
    %w[script style img href onclick alert body{].each { |bad| assert_not_includes html, bad }
  end

  test 'unknown kinds and empty views are refused with what to fix' do
    assert_raises(ArgumentError) { build({ title: 'X', kind: 'pie' }) }
    assert_raises(ArgumentError) { build({ title: 'X', kind: 'table', columns: [], rows: [] }) }
    assert_raises(ArgumentError) { build({ title: 'X', kind: 'html', html: '<script>1</script>' }) }
  end
end
