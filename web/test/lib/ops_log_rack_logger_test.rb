# frozen_string_literal: true

require 'test_helper'

class OpsLogRackLoggerTest < ActiveSupport::TestCase
  teardown { Thread.current[:ops_log_context] = nil }

  test 'Rails-format delegation preserves the original application exception and finishes once' do
    original = ArgumentError.new('application failure')
    calls = 0
    app = lambda do |_env|
      calls += 1
      raise original
    end
    logger = OpsLog::RackLogger.new(app)
    events = []
    callback = ->(*args) { events << args }
    OpsLog.with_format('rails') do
      ActiveSupport::Notifications.subscribed(callback, 'request.action_dispatch') do
        assert_same original, assert_raises(ArgumentError) { logger.call(Rack::MockRequest.env_for('/logger-test')) }
      end
    end
    assert_equal 1, calls
    assert_equal 1, events.size
  end

  test 'structured formats preserve application exceptions and clear request context' do
    %w[json text].each do |format|
      original = ArgumentError.new('structured application failure')
      logger = OpsLog::RackLogger.new(->(_env) { raise original })
      events = []
      OpsLog.with_format(format) do
        ActiveSupport::Notifications.subscribed(->(*args) { events << args }, 'request.action_dispatch') do
          assert_same original, assert_raises(ArgumentError) { logger.call(Rack::MockRequest.env_for('/logger-test')) }
        end
      end
      assert_nil Thread.current[:ops_log_context]
      assert_equal 1, events.size
    end
  end

  test 'a finishing subscriber failure cannot replace an application exception or leak tags' do
    %w[rails json text].each do |format|
      original = ArgumentError.new('primary failure')
      tagged = ActiveSupport::TaggedLogging.new(Logger.new(StringIO.new))
      logger = OpsLog::RackLogger.new(->(_env) { raise original }, ['request-tag'])
      logger.stubs(:logger).returns(tagged)
      calls = 0
      observer = lambda do |*|
        calls += 1
        raise 'subscriber failure'
      end
      OpsLog.with_format(format) do
        ActiveSupport::Notifications.subscribed(observer, 'request.action_dispatch') do
          assert_same original, assert_raises(ArgumentError) { logger.call(Rack::MockRequest.env_for('/logger-test')) }
        end
      end
      assert_equal 1, calls
      assert_empty tagged.formatter.current_tags
      assert_nil Thread.current[:ops_log_context]
    end
  end

  test 'frozen streaming responses finish only when closed and observer failures do not break delivery' do
    tagged = ActiveSupport::TaggedLogging.new(Logger.new(StringIO.new))
    logger = OpsLog::RackLogger.new(->(_env) { [200, {}, ['hello']].freeze }, ['request-tag'])
    logger.stubs(:logger).returns(tagged)
    calls = 0
    observer = lambda do |*|
      calls += 1
      raise 'subscriber failure'
    end
    OpsLog.with_format('json') do
      ActiveSupport::Notifications.subscribed(observer, 'request.action_dispatch') do
        response = logger.call(Rack::MockRequest.env_for('/logger-test'))
        assert_equal 200, response[0]
        assert_equal ['request-tag'], tagged.formatter.current_tags
        content = +''
        response[2].each { |part| content << part }
        assert_equal 'hello', content
        assert_equal 0, calls
        response[2].close
        response[2].close
      end
    end
    assert_equal 1, calls
    assert_empty tagged.formatter.current_tags
    assert_nil Thread.current[:ops_log_context]
  end
end
