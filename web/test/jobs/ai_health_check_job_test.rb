# frozen_string_literal: true

require 'test_helper'

class AiHealthCheckJobTest < ActiveJob::TestCase
  test 'runs a provider check with the trigger' do
    OpencodeHealth.expects(:check!).with(trigger: 'manual')
    AiHealthCheckJob.perform_now('manual')
  end

  test 'is scheduled in the production recurring config' do
    config = YAML.load_file(Rails.root.join('config/recurring.yml')).fetch('production')
    assert_equal 'AiHealthCheckJob', config.dig('ai_health_check', 'class')
  end

  test 'the nightly retention job prunes old agent runs but keeps recent ones' do
    AiAgentRun.delete_all
    AiAgentRun.create!(outcome: 'ok', occurred_at: 200.days.ago)
    recent = AiAgentRun.create!(outcome: 'ok', occurred_at: 1.day.ago)
    DataRetentionJob.perform_now
    assert_equal [recent.id], AiAgentRun.pluck(:id)
  end
end
