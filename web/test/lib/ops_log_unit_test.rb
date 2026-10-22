# frozen_string_literal: true

require 'test_helper'

class OpsLogUnitTest < ActiveSupport::TestCase
  def formatted(message, tags: [], time: Time.utc(2026, 10, 21, 12, 0, 0.25r))
    formatter = Logger::Formatter.new
    formatter.extend(ActiveSupport::TaggedLogging::Formatter)
    formatter.extend(OpsLog::Formatter)
    tags.each { |tag| formatter.push_tags(tag) }
    formatter.call('INFO', time, nil, message)
  end

  test 'an event is one JSON line with a timestamp, level and its fields' do
    line = formatted(OpsLog::Event.new('upload', { files: [{ size: 3 }], outcome: 'accepted' }))
    assert line.end_with?("\n")
    assert_equal 1, line.lines.size
    assert_equal({ 'ts' => '2026-10-21T12:00:00.250Z', 'level' => 'info', 'event' => 'upload', 'files' => [{ 'size' => 3 }], 'outcome' => 'accepted' }, JSON.parse(line))
  end

  test 'a plain string becomes a log event with the request id from the tags' do
    parsed = JSON.parse(formatted('Puma line: hello', tags: ['req-1']))
    assert_equal 'log', parsed['event']
    assert_equal 'req-1', parsed['request_id']
    assert_equal 'Puma line: hello', parsed['msg']
  end

  test 'a multi-line message stays on one line and is redacted' do
    line = formatted("Boom for jane@example.com\n  at card 4111 1111 1111 1111\n  password=hunter2\n\e[31mred\e[0m")
    assert_equal 1, line.lines.size
    assert_no_match(/jane@|4111|hunter2|\e/, line)
  end

  test 'under systemd the line carries the journald priority prefix' do
    ENV['JOURNAL_STREAM'] = '8:1234'
    assert formatted('x').start_with?('<6>{')
    assert_match(/\A<4>/, Logger::Formatter.new.tap { |f| f.extend(OpsLog::Formatter) }.call('WARN', Time.now.utc, nil, 'x'))
  ensure
    ENV.delete('JOURNAL_STREAM')
  end

  test 'an event prints readably for development and the log taps' do
    event = OpsLog::Event.new('request', { method: 'GET', path: '/x', note: 'two words', ids: [1, 2] })
    assert_equal 'request method=GET path=/x note="two words" ids=[1,2]', event.to_s
  end

  test 'values are bounded and blanks dropped' do
    cleaned = OpsLog.clean(a: nil, b: '', c: 'x' * 1000, d: (1..100).to_a, e: :sym, f: Time.utc(2026, 1, 1))
    assert_equal %i[c d e f], cleaned.keys
    assert_equal 300, cleaned[:c].size
    assert_equal 30, cleaned[:d].size
    assert_equal 'sym', cleaned[:e]
    assert_equal '2026-01-01T00:00:00.000Z', cleaned[:f]
  end

  test 'safe_text removes tokens, key=value secrets, emails, numbers, quoted values and object dumps' do
    text = 'failed for "Jane Roe" a@b.co token=abc123 Bearer abcdefghijklmnop #<Customer id: 5, email: "x@y.z"> acct 021000021 and 3 items'
    safe = OpsLog.safe_text(text)
    ['Jane Roe', 'a@b.co', 'abc123', 'abcdefghijklmnop', 'x@y.z', '021000021'].each { |value| assert_not_includes safe, value }
    assert_includes safe, '3 items'
    assert_equal 20, OpsLog.safe_text('x' * 50, 20).size
  end

  test 'an email is only ever logged as a short hash' do
    assert_nil OpsLog.email_hash('')
    assert_equal OpsLog.email_hash('A@B.co '), OpsLog.email_hash('a@b.co')
    assert_match(/\A\h{12}\z/, OpsLog.email_hash('a@b.co'))
  end

  test 'error fields keep the class, a redacted message and only application frames' do
    error = begin
      raise ArgumentError, 'bad "private" value'
    rescue ArgumentError => e
      e
    end
    fields = OpsLog.error_fields(error)
    assert_equal 'ArgumentError', fields[:error_class]
    assert_not_includes fields[:error_message], 'private'
    assert(fields[:error_at].all? { |frame| frame.start_with?('test/') || frame.start_with?('lib/') || frame.start_with?('app/') })
  end

  test 'quiet requests are only fast, successful probes and polls' do
    quiet = ->(**args) { OpsLog::Noise.quiet_request?(method: 'GET', path: '/up', status: 200, user_id: nil, duration_ms: 1, **args) }
    assert quiet.call
    assert quiet.call(path: '/up/deep')
    assert quiet.call(path: '/login')
    assert_not quiet.call(path: '/login', method: 'POST')
    assert_not quiet.call(path: '/dashboard')
    assert_not quiet.call(status: 500)
    assert_not quiet.call(status: 404)
    assert_not quiet.call(path: '/', user_id: 7)
  end

  test 'the summary flushes by itself once the window has passed' do
    OpsLog::Noise.reset!
    ENV['RUPERT_LOG_SUMMARY_SECONDS'] = '0'
    io = StringIO.new
    tap_logger = Logger.new(io)
    Rails.logger.broadcast_to(tap_logger)
    OpsLog::Noise.count('GET /up 200', 1.5)
    assert_includes io.string, 'noise_summary'
    assert_includes io.string, 'GET /up 200'
  ensure
    Rails.logger.stop_broadcasting_to(tap_logger)
    ENV.delete('RUPERT_LOG_SUMMARY_SECONDS')
    OpsLog::Noise.reset!
  end

  test 'sentry events are redacted before they leave the server' do
    event = Sentry::Event.new(configuration: Sentry::Configuration.new)
    event.message = 'Failed for a@b.co with token=abc123'
    result = OpsLog.sentry_before_send(event)
    assert_no_match(/a@b\.co|abc123/, result.message)
    error = Struct.new(:value).new('card 4111111111111111 for "Jane Roe"')
    errored = Struct.new(:message, :request, :exception).new(nil, nil, Struct.new(:values).new([error]))
    OpsLog.sentry_before_send(errored)
    assert_no_match(/4111|Jane/, error.value)
  end

  test 'the structured format is json in production and the rails log elsewhere' do
    OpsLog.with_format(nil) do
      assert_equal 'rails', OpsLog.format
      ENV['RUPERT_LOG_FORMAT'] = 'json'
    end
    OpsLog.with_format(nil) { assert_equal 'json', OpsLog.format }
  ensure
    ENV.delete('RUPERT_LOG_FORMAT')
  end
end
