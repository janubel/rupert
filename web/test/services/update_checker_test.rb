# frozen_string_literal: true

require 'test_helper'

class UpdateCheckerTest < ActiveSupport::TestCase
  SHA = 'a' * 40

  test 'behind build reports how many newer changes exist' do
    compare = { 'status' => 'ahead', 'ahead_by' => 3, 'html_url' => 'https://github.com/techmore/rupert/compare/x...main',
                'commits' => [{ 'commit' => { 'message' => "Old\n\nbody" } }, { 'commit' => { 'message' => "Newest change\n\nmore" } }] }
    result = UpdateChecker.build_result(SHA, compare)
    assert result.available?
    assert_equal 3, result.behind_by
    assert_equal 'Newest change', result.latest_message
  end

  test 'identical, diverged and malformed comparisons are not updates' do
    assert_not UpdateChecker.build_result(SHA, { 'status' => 'identical', 'ahead_by' => 0 }).available?
    assert_not UpdateChecker.build_result(SHA, { 'status' => 'behind', 'ahead_by' => 0 }).available?
    assert_not UpdateChecker.build_result(SHA, {}).available?
  end

  test 'refresh swallows fetch failures' do
    assert_nil UpdateChecker.refresh!(current: SHA) { |_path| raise 'offline' }
  end

  test 'refresh asks GitHub to compare the running build with main' do
    path = nil
    UpdateChecker.refresh!(current: SHA) do |requested|
      path = requested
      { 'status' => 'identical' }
    end
    assert_equal "/repos/techmore/rupert/compare/#{SHA}...main", path
  end

  test 'checking is off in tests so no request is ever made' do
    assert_not UpdateChecker.enabled?
    assert_nil UpdateChecker.pending(current: SHA)
  end
end
