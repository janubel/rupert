# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

class AskRupertGuideTest < ActiveSupport::TestCase
  include AskRupertHelper

  teardown { Current.reset }

  test 'where_is finds pages the person can open, with links' do
    admin = person('admin')
    found = AskRupert::Guide.new(admin).where_is('where do I find the timesheets?')
    assert_equal 'Timesheets', found[:pages].first[:title]
    assert_equal '/people/timesheets', found[:pages].first[:path]
  end

  test 'a page the person cannot open is never linked, only named as not available' do
    cashier = person('cashier')
    found = AskRupert::Guide.new(cashier).where_is('payroll')
    assert_empty found[:pages].select { |page| page[:path].to_s.include?('pay_runs') }
    assert_includes found[:not_available], 'Payroll'
    assert_includes AskRupert::Guide.new(person('admin')).where_is('payroll')[:pages].map { |page| page[:path] }, '/people/pay_runs'
  end

  test 'menus that are not pages are answered with where they live' do
    found = AskRupert::Guide.new(person('reader')).where_is('how do I switch to dark mode')
    assert_match(/Account menu/, found[:elsewhere].first[:where])
  end

  test 'how_do_i returns lessons the person is allowed, with steps and a learning link' do
    found = AskRupert::Guide.new(person('admin')).how_do_i('how do I give someone access')
    lesson = found[:lessons].first
    assert_equal 'Give the right access', lesson[:title]
    assert_equal '/learning/access', lesson[:path]
    assert_predicate lesson[:steps], :any?

    none = AskRupert::Guide.new(person('cashier')).how_do_i('how do I give someone access')
    assert_empty none[:lessons].select { |entry| entry[:path] == '/learning/access' }
  end

  test 'a page is paired with its lesson when one exists' do
    link = AskRupert::Guide.new(person('admin')).lesson_link('/syncs')
    assert_equal '/learning/sync', link[:path]
  end

  test 'empty and stop-word-only questions match nothing' do
    guide = AskRupert::Guide.new(person('admin'))
    assert_empty guide.where_is('how do I')[:pages]
    assert_empty guide.how_do_i('')[:lessons]
  end
end
