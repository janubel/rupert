# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
if ENV['COVERAGE'] == '1'
  require 'simplecov'
  SimpleCov.command_name "test-#{ENV.fetch('TEST_ENV_NUMBER', Process.pid)}"
end
require_relative '../config/environment'
require 'rails/test_help'
require_relative 'support/upload_fixtures'

require 'minitest/autorun'
require 'minitest/mock'
require 'webmock/minitest'
require 'mocha/minitest'

# Opens a push window for a platform: unfreezes it (Square defaults to frozen
# while its platform update is in progress) and records the two approvals the
# multi-approval gate requires.
module PushGuardTestHelper
  def open_push_window!(platform)
    PlatformPushGuard.unfreeze!(platform, actor: 'tester@example.com')
    PlatformPushGuard.approve!(platform, email: 'approver-a@example.com')
    PlatformPushGuard.approve!(platform, email: 'approver-b@example.com')
    assert PlatformPushGuard.window_open?(platform), "expected a push window to be open for #{platform}"
    # Writes now require an explicit confirmation (the old window no longer
    # gates anything); tests opt in once per setup.
    Current.confirm_push!
  end
end

module ActiveSupport
  class TestCase
    include PushGuardTestHelper

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    if ENV['COVERAGE'] == '1'
      parallelize_setup { |worker| SimpleCov.command_name("test-worker-#{worker}") }
      parallelize_teardown { SimpleCov.result }
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
