# frozen_string_literal: true

require 'test_helper'

class DataGuideTest < ActiveSupport::TestCase
  def keys(text) = DataGuide.match(text).map(&:key)

  test 'questions map to the topics they are about, most hits first' do
    assert_equal %w[comparison], keys('How did last month compare with the month before?').first(1)
    assert_equal 'tax', keys('How much sales tax did we collect last month?').first
    assert_equal %w[people], keys('How many hours did the team work last pay week?').first(1)
    assert_includes keys('Are there timesheets waiting for approval?'), 'people'
    assert_equal 'queues', keys('Are there paid online orders that have not shipped yet?').first
    assert_equal [], keys('hello there')
    assert_operator keys('sales tax refunds expenses books stock hours sync').size, :<=, DataGuide::MAX_TOPICS
  end

  test 'every topic names tools that exist, and the guide renders every card' do
    names = Mcp::Registry.tools.map(&:tool_name)
    DataGuide.topics.each { |topic| assert_empty topic.tools - names, "#{topic.key} names a missing tool" }
    assert_equal DataGuide.topics.size, DataGuide.markdown.scan(/^### /).size
    assert_equal %w[sales_summary period_review sales_tax_report], DataGuide.tools_for([DataGuide.find('sales'), DataGuide.find('tax')])
  end
end
