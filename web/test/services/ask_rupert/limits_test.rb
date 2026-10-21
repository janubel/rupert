# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

class AskRupertLimitsTest < ActiveSupport::TestCase
  include AskRupertHelper

  setup do
    @user = person('cashier')
    @config = AskRupert::Config.new('rate_limit_count' => 3, 'rate_limit_window_minutes' => 10, 'daily_cap' => 5)
  end

  teardown { Current.reset }

  def ask!(outcome: 'ok', at: Time.current)
    AskRupert::Usage.create!(user: @user, outcome: outcome, created_at: at)
  end

  test 'a quiet person is allowed' do
    assert AskRupert::Limits.new(@user, config: @config).check.allowed?
  end

  test 'over the window rate they are told how long to wait, with no lockout after the window passes' do
    3.times { |i| ask!(at: (9 - i).minutes.ago) }
    decision = AskRupert::Limits.new(@user, config: @config).check
    assert_not decision.allowed?
    assert_equal :rate, decision.reason
    assert_includes decision.message, 'Give it'
    assert_operator decision.retry_after, :<=, 60 * 2

    travel 11.minutes do
      assert AskRupert::Limits.new(@user, config: @config).check.allowed?
    end
  end

  test 'a daily cap applies and frees up as the day rolls' do
    5.times { |i| ask!(at: (23 - i).hours.ago) }
    decision = AskRupert::Limits.new(@user, config: @config).check
    assert_equal :daily, decision.reason
    assert_includes decision.message, 'Help (?)'
    ask_oldest = AskRupert::Usage.order(:created_at).first
    ask_oldest.update!(created_at: 25.hours.ago)
    assert AskRupert::Limits.new(@user, config: @config).check.allowed?
  end

  test 'only one reply may be in flight, and a stuck one stops counting after a few minutes' do
    ask!(outcome: 'pending')
    decision = AskRupert::Limits.new(@user, config: @config).check
    assert_equal :busy, decision.reason
    travel(AskRupert::Message::STALE_AFTER + 1.minute) do
      assert AskRupert::Limits.new(@user, config: @config).check.allowed?
    end
  end

  test 'failed replies and limited attempts do not count against anyone' do
    10.times { ask!(outcome: 'error') }
    10.times { ask!(outcome: 'limited') }
    assert AskRupert::Limits.new(@user, config: @config).check.allowed?
  end

  test 'limits are per person' do
    3.times { ask! }
    other = person('manager')
    assert AskRupert::Limits.new(other, config: @config).check.allowed?
  end

  test 'clearing a chat does not reset the count' do
    conversation, = pending_turn(@user, 'hello')
    AskRupert::Usage.update_all(outcome: 'ok')
    2.times { ask! }
    conversation.destroy
    assert_not AskRupert::Limits.new(@user, config: @config).check.allowed?
  end
end
