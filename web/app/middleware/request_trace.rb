# frozen_string_literal: true

require 'logger'

# Keeps the last few requests of each signed-in browser session in memory —
# their log lines and SQL queries — so a report filed from the ladybug can
# carry what the server just did. Nothing is written to disk. Entries are
# capped, expire, and are passed through FeedbackSanitizer when a report is
# built. The store is per process; Rupert runs one web process, and a report
# from another process simply carries no server lines.
module RequestTrace
  MAX_REQUESTS = 12
  MAX_SESSIONS = 100
  TTL = 30.minutes
  MAX_LINES = 40
  MAX_LINE = 300
  MAX_QUERIES = 30
  MAX_QUERY = 240
  MAX_ERRORS = 100
  SKIPPED_PATHS = %r{\A(/up|/assets|/cable|/rails/active_storage|/feedback_reports)}
  KEY = 'rupert.trace_key'
  THREAD_KEY = :rupert_request_trace

  # Lines and queries seen while one request ran on this thread.
  class Capture
    attr_reader :lines, :queries

    def initialize
      @lines = []
      @queries = []
    end

    def add_line(text)
      @lines << text.to_s.strip.first(MAX_LINE) if @lines.size < MAX_LINES && text.to_s.strip.present?
    end

    def add_query(name, duration_ms, sql, cached)
      return if @queries.size >= MAX_QUERIES

      @queries << { name: name.to_s.first(60), ms: duration_ms.round(1), cached: cached ? true : nil, sql: sql.to_s.first(MAX_QUERY) }.compact
    end
  end

  # Log device that hands each formatted line to the capture of the current thread.
  class LineSink
    def write(text)
      Thread.current[THREAD_KEY]&.add_line(text.to_s)
      text.to_s.bytesize
    end

    def close; end
  end

  # Process-wide ring of recent error lines for the recent_errors MCP tool.
  class ErrorSink
    def write(text)
      RequestTrace.record_error(text.to_s.strip) if text.to_s.strip.present?
      text.to_s.bytesize
    end

    def close; end
  end

  Entry = Struct.new(:request_id, :at, :method, :path, :status, :duration_ms, :lines, :queries, keyword_init: true)

  @mutex = Mutex.new
  @sessions = {}
  @errors = []

  class << self
    def install!
      return if @installed

      @installed = true
      attach_logger(LineSink.new, Logger::INFO)
      attach_logger(ErrorSink.new, Logger::ERROR)
      ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
        payload = event.payload
        next if payload[:name] == 'SCHEMA' || Thread.current[THREAD_KEY].nil?

        Thread.current[THREAD_KEY].add_query(payload[:name], event.duration, FeedbackSanitizer.scrub_sql(payload[:sql]), payload[:cached])
      end
      Rails.error.subscribe(ErrorReporter.new)
    end

    def attach_logger(sink, level)
      plain = Logger.new(sink, level: level)
      plain.formatter = proc { |severity, _time, _progname, message| "#{severity} #{message.is_a?(String) ? message : message.inspect}\n" }
      # Deliberately not TaggedLogging: BroadcastLogger runs a tagged block once per
      # logger that responds to tagged, which would run every request three times.
      Rails.logger.broadcast_to(plain)
    end

    def start
      Thread.current[THREAD_KEY] = Capture.new
    end

    def finish(key:, request_id:, method:, path:, status:, started:)
      capture = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = nil
      return if capture.nil? || key.blank?

      entry = Entry.new(request_id: request_id.to_s.first(64), at: Time.current, method: method, path: path.to_s.first(300), status: status,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round, lines: capture.lines, queries: capture.queries)
      @mutex.synchronize do
        list = (@sessions[key] ||= [])
        list << entry
        list.shift while list.size > MAX_REQUESTS
        prune
      end
    end

    # The session's recent requests, oldest first, without those older than TTL.
    def recent(key)
      return [] if key.blank?

      @mutex.synchronize { (@sessions[key] || []).select { |entry| entry.at > TTL.ago }.dup }
    end

    def record_error(text)
      @mutex.synchronize do
        @errors << { at: Time.current, text: text.first(500) }
        @errors.shift while @errors.size > MAX_ERRORS
      end
    end

    def recent_errors(limit = 20)
      @mutex.synchronize { @errors.last(limit).reverse }
    end

    def reset!
      @mutex.synchronize do
        @sessions.clear
        @errors.clear
      end
    end

    private

    def prune
      @sessions.delete_if { |_key, list| list.empty? || list.last.at < TTL.ago }
      @sessions.shift while @sessions.size > MAX_SESSIONS
    end
  end

  # Rails.error reports (rescued and unhandled exceptions) become error lines.
  class ErrorReporter
    def report(error, handled:, severity:, context:, source: nil)
      RequestTrace.record_error("#{severity.to_s.upcase} #{error.class}: #{error.message} (#{source}#{handled ? ', handled' : ''})")
    end
  end

  # Wraps each request; the controller names the browser session (env KEY) once
  # it has identified the signed-in user, which is what makes the capture kept.
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if env['REQUEST_METHOD'] == 'HEAD' || env['PATH_INFO'].to_s.match?(SKIPPED_PATHS)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      RequestTrace.start
      status, headers, body = @app.call(env)
      finish(env, status, started)
      [status, headers, body]
    rescue StandardError
      finish(env, 500, started)
      raise
    end

    private

    def finish(env, status, started)
      key = env[KEY]
      request = ActionDispatch::Request.new(env) if key
      RequestTrace.finish(key: key, request_id: env['action_dispatch.request_id'], method: env['REQUEST_METHOD'],
        path: request&.filtered_path, status: status, started: started)
    rescue StandardError
      Thread.current[THREAD_KEY] = nil
    end
  end
end
