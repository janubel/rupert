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

      call_structured_app(request, env)
    end

    def call_structured_app(request, env)
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
      finish_request_instrumentation(handle, tag_count)
    end

    def finish_request_instrumentation(handle, tag_count)
      begin
        handle.finish
      ensure
        begin
          logger.pop_tags(tag_count) if logger.respond_to?(:pop_tags) && tag_count.to_i.positive?
        ensure
          ActiveSupport::LogSubscriber.flush_all!
        end
      end
    rescue StandardError
      # Observer failures must not replace application errors or interrupt body
      # delivery. Tags and flushing still get their cleanup, in every format.
      nil
    ensure
      # Finishing subscribers and flushing can create context too. Clear it last.
      Thread.current[:ops_log_context] = nil
    end
  end
end
