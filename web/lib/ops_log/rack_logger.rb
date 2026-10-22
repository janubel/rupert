# frozen_string_literal: true

require 'rails/rack/logger'

module OpsLog
  # Replaces Rails::Rack::Logger. With a structured format it writes no "Started ..."
  # line and instead writes one request line when the response body is closed (so the
  # duration covers streaming too). With the `rails` format it behaves exactly like the
  # class it replaces. Request-id tagging, instrumentation and flushing are unchanged.
  class RackLogger < Rails::Rack::Logger
    private

    def call_app(request, env)
      return super unless OpsLog.single_line?

      tag_count = env['rails.rack_logger_tag_count']
      instrumenter = ActiveSupport::Notifications.instrumenter
      handle = instrumenter.build_handle('request.action_dispatch', { request: request })
      handle.start
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Thread.current[:ops_log_context] = { request_id: request.request_id }

      response = @app.call(env)
      status, headers, body = response
      body = ::Rack::BodyProxy.new(body) { finish(request, env, status, headers, started, handle, tag_count) }
      return [status, headers, body] if response.frozen?

      response[2] = body
      response
    rescue Exception => error
      finish(request, env, 500, {}, started || Process.clock_gettime(Process::CLOCK_MONOTONIC), handle, tag_count, error: error)
      raise
    end

    def finish(request, env, status, headers, started, handle, tag_count, error: nil)
      OpsLog::RequestLine.emit(request, env, status, headers, started, error: error)
    ensure
      Thread.current[:ops_log_context] = nil
      finish_request_instrumentation(handle, tag_count)
    end
  end
end
