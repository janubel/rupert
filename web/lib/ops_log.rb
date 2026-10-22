# frozen_string_literal: true

require 'json'
require 'logger'
require 'digest'
require 'time'

# Rupert's operational logging: one structured line per request, structured
# events for what an operator actually needs (sign-ins, denials, validation
# failures, uploads, syncs, jobs, deploys), and no values.
#
# This file and lib/ops_log/ are required explicitly from
# config/initializers/ops_log.rb and are not autoloaded (see application.rb):
# the formatter and middleware are installed at boot and must not be reloaded.
#
# Rules every event follows:
# * Fields name things (ids, kinds, counts, durations). They never carry what a
#   person typed, file contents, card or bank numbers, tokens, or email bodies.
# * Free text (an error message) goes through OpsLog.safe_text first.
# * Logging never raises into the code being logged.
module OpsLog
  LEVELS = { debug: Logger::DEBUG, info: Logger::INFO, warn: Logger::WARN, error: Logger::ERROR, fatal: Logger::FATAL }.freeze
  FORMATS = %w[json text rails].freeze
  FILTERED = '[FILTERED]'

  EMAIL = /[\w.+%-]+@[\w-]+(?:\.[\w-]+)+/
  LONG_NUMBER = /(?<![\w.])\d(?:[ -]?\d){5,}(?!\w)/
  QUOTED_VALUE = /"[^"\n]+"/
  INSPECT_DUMP = /#<[A-Z][\w:]*[^>\n]*>/
  ANSI = /\e\[[\d;]*m/
  SECRET_SEGMENT = /\A(?:rupert_[\w-]+|(?=[^\d]*\d)(?=[^A-Za-z]*[A-Za-z])[A-Za-z0-9_-]{24,})\z/

  Event = Struct.new(:name, :fields) do
    # The plain-text form: what development, the log taps and the ladybug report see.
    def to_s
      parts = fields.map { |key, value| "#{key}=#{OpsLog.text_value(value)}" }
      ([name] + parts).join(' ')
    end

    # Rails' default formatter and Logger::Formatter print a non-string message with inspect.
    def inspect = to_s
  end

  class << self
    attr_writer :format

    # json (production), text (one readable line per request and event) or
    # rails (Rails' own multi-line development log). RUPERT_LOG_FORMAT overrides.
    def format
      @format ||= begin
        value = ENV['RUPERT_LOG_FORMAT'].to_s.downcase
        if FORMATS.include?(value)
          value
        else
          defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production? ? 'json' : 'rails'
        end
      end
    end

    def json? = format == 'json'

    # True when requests and jobs log one line each instead of Rails' default lines.
    def single_line? = format != 'rails'

    def with_format(value)
      previous = @format
      @format = value
      yield
    ensure
      @format = previous
    end

    def slow_request_ms = (ENV['RUPERT_SLOW_REQUEST_MS'].presence || 2000).to_i

    def quiet_job_ms = (ENV['RUPERT_LOG_QUIET_JOB_MS'].presence || 1000).to_i

    def summary_seconds = (ENV['RUPERT_LOG_SUMMARY_SECONDS'].presence || 300).to_i

    # Thread-local facts shared by every line written while one request or job runs.
    def context = (Thread.current[:ops_log_context] ||= {})

    def with_context(**values)
      previous = Thread.current[:ops_log_context]
      Thread.current[:ops_log_context] = (previous || {}).merge(values)
      yield
    ensure
      Thread.current[:ops_log_context] = previous
    end

    # Writes one structured event. `persist: false` keeps a warning or error out of the
    # recent-activity table (the request line, which OpsLog::RequestLine persists itself).
    def event(name, level: :info, persist: true, **fields)
      fields = clean(fields)
      fields[:request_id] ||= context[:request_id] if context[:request_id]
      logger = Rails.logger
      logger&.add(LEVELS.fetch(level), Event.new(name.to_s, fields))
      if persist && LEVELS.fetch(level) >= Logger::WARN
        # Tells the request line that something more specific already explains this response.
        Thread.current[:ops_log_context][:explained] = true if Thread.current[:ops_log_context]
        OpsLog::Activity.record(name.to_s, level, fields)
      end
      nil
    rescue StandardError
      nil
    end

    # The outcome of an import (bank statement, report, CSV): counts and ids, never rows.
    def import(kind:, outcome:, **counts)
      event('import', level: outcome.to_s == 'ok' ? :info : :warn, kind: kind, outcome: outcome, **actor_fields, **counts)
    end

    # Drops blanks and bounds every value so a careless caller cannot write a novel.
    def clean(fields)
      fields.each_with_object({}) do |(key, value), out|
        next if value.nil? || value == ''

        out[key.to_sym] = clean_value(value)
      end
    end

    def clean_value(value)
      case value
      when String then value.scrub('').first(300)
      when Symbol then value.to_s
      when Numeric, true, false then value
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(3)
      when Array then value.first(30).map { |item| clean_value(item) }
      when Hash then value.first(30).to_h { |key, item| [key.to_s, clean_value(item)] }
      else value.to_s.first(300)
      end
    end

    def text_value(value)
      case value
      when String then value.match?(/[\s="]/) ? value.inspect : value
      when Array then "[#{value.map { |item| text_value(item) }.join(',')}]"
      when Hash then "{#{value.map { |key, item| "#{key}:#{text_value(item)}" }.join(',')}}"
      else value.to_s
      end
    end

    # Free text that may echo a value (an exception message, a flash). Best effort: it
    # removes tokens, key=value pairs the request log filters, emails, long digit runs and
    # object dumps, then bounds the length. `strict` (the default, for exception messages)
    # also hides every double-quoted string; plain log lines from libraries keep theirs.
    def safe_text(text, max = 200, strict: true)
      out = FeedbackSanitizer.scrub_text(text.to_s.scrub('').gsub(ANSI, ''))
      out = out.gsub(EMAIL, '[email]').gsub(INSPECT_DUMP, '#<object>').gsub(LONG_NUMBER, '[number]')
      out = out.gsub(QUOTED_VALUE, '"[value]"') if strict
      out.squish.first(max)
    end

    # A request path without its query and with token-looking segments hidden (a long mix of
    # letters and digits, or a Rupert API token). Record ids are shorter and stay visible.
    def safe_path(path)
      base = path.to_s.split('?', 2).first.to_s
      base.split('/', -1).map { |segment| segment.sub(/\.\w+\z/, '').match?(SECRET_SEGMENT) ? ':token' : segment }.join('/').first(300)
    end

    # Names of the query parameters, never their values (a search box holds a person's name).
    def query_keys(path)
      query = path.to_s.split('?', 2)[1]
      return if query.blank?

      query.split('&').filter_map { |pair| pair.split('=', 2).first.presence&.first(40) }.uniq.first(10)
    end

    # Exception facts safe to log: class, a redacted message, and the first application frames.
    def error_fields(error, frames: 4)
      return {} unless error

      own = Array(error.backtrace).filter_map { |line| line.delete_prefix("#{Rails.root}/") if line.start_with?(Rails.root.to_s) }
      own.reject! { |line| line.start_with?('lib/ops_log', 'app/middleware') }
      { error_class: error.class.name, error_message: safe_text(error.message), error_at: own.first(frames) }
    end

    # Hash of an email so repeated failures can be correlated without writing the address.
    def email_hash(email)
      return if email.blank?

      Digest::SHA256.hexdigest("rupert-log:#{email.to_s.strip.downcase}").first(12)
    end

    # Sentry's before_send: no request data, cookies or headers beyond two, and exception
    # messages redacted like every other log line.
    def sentry_before_send(event, _hint = nil)
      event.request&.data = nil
      event.request&.cookies = nil
      event.request&.headers = event.request&.headers&.slice('User-Agent', 'X-Request-Id')
      event.try(:exception)&.values&.each { |error| error.value = safe_text(error.value, 300) if error.value }
      event.message = safe_text(event.message, 300) if event.message
      event
    end

    # Written once when a web or job process starts: which build, what logging is on.
    def boot_event
      role = process_role or return
      event('app.boot', persist: false, process: role, revision: (BuildInfo.current.revision if defined?(BuildInfo)),
        rails: Rails.version, ruby: RUBY_VERSION, env: Rails.env.to_s, log_format: format, log_level: level_name,
        slow_request_ms: slow_request_ms, sentry: defined?(Sentry) && Sentry.initialized?, pid: Process.pid)
    rescue StandardError
      nil
    end

    def level_name
      LEVELS.key(Rails.logger.level)&.to_s || Rails.logger.level.to_s
    end

    def process_role
      return if Rails.env.test? || defined?(Rake) && Rake.respond_to?(:application) && Rake.application.top_level_tasks.any?

      program = File.basename($PROGRAM_NAME)
      return 'jobs' if program.match?(/jobs|solid_queue/)

      'web' if program.include?('puma')
    end

    # The tenant and signed-in user of the current request or job, if any.
    def actor_fields
      user = Current.user
      { user_id: user&.id, tenant_id: Current.tenant_id || user&.tenant_id, role: user&.role }
    rescue StandardError
      {}
    end
  end
end

require_relative 'ops_log/formatter'
require_relative 'ops_log/noise'
require_relative 'ops_log/activity'
require_relative 'ops_log/request_line'
require_relative 'ops_log/rack_logger'
require_relative 'ops_log/controller_context'
require_relative 'ops_log/subscribers'
require_relative 'ops_log/migrations'
