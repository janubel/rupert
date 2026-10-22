# frozen_string_literal: true

module OpsLog
  # The single line written for every request that reaches the app (including the ones
  # that never find a controller: 404s, blocked hosts, bad requests). Built from the
  # Rack env, the response headers, and what the controller left in env['rupert.ops']
  # (OpsLog::Subscribers::ProcessAction). Query values, bodies and cookies are never read.
  module RequestLine
    ENV_KEY = 'rupert.ops'

    class << self
      def emit(request, env, status, headers, started, error: nil)
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        ops = env[ENV_KEY] || {}
        status = status.to_i
        route = route_for(request)
        params = request.path_parameters
        fields = {
          request_id: request.request_id, method: request.request_method,
          path: OpsLog.safe_path(request.path), route: route,
          controller: params[:controller], action: params[:action], format: ops[:format], status: status, duration_ms: duration,
          db_ms: ops[:db_ms], view_ms: ops[:view_ms], allocations: ops[:allocations], bytes: bytes(headers, ops),
          user_id: ops[:user_id], tenant_id: ops[:tenant_id], role: ops[:role], ip: request.remote_ip,
          query_keys: OpsLog.query_keys(request.fullpath), params: ops[:params_keys], location: location(headers)
        }
        fields.merge!(OpsLog.error_fields(error)) if error
        fields.merge!(ops[:error]) if ops[:error] && !error
        slow = duration >= OpsLog.slow_request_ms
        fields[:slow] = true if slow
        write(fields, status, slow, explained: ops[:explained] || Thread.current[:ops_log_context]&.fetch(:explained, nil))
      rescue StandardError
        nil
      end

      private

      def write(fields, status, slow, explained:)
        if Noise.quiet_request?(method: fields[:method], path: fields[:path], status: status, user_id: fields[:user_id], duration_ms: fields[:duration_ms])
          Noise.count("#{fields[:method]} #{fields[:path]} #{status}", fields[:duration_ms])
          return OpsLog.event('request', level: :debug, persist: false, **fields)
        end

        level = if status >= 500 then :error
        elsif slow || (status >= 400 && status != 404) then :warn
        else :info
        end
        # A 4xx that a specific event already explains (permission denied, form rejected,
        # sign-in failure) is persisted by that event instead of here.
        persist = status >= 500 || slow || (status.between?(400, 499) && status != 404 && !explained)
        OpsLog.event('request', level: level, persist: persist, **fields)
      end

      def route_for(request)
        request.route_uri_pattern if request.respond_to?(:route_uri_pattern)
      rescue StandardError
        nil
      end

      def bytes(headers, ops)
        length = headers.respond_to?(:[]) ? (headers['content-length'] || headers['Content-Length']) : nil
        length.present? ? length.to_i : ops[:bytes]
      end

      def location(headers)
        value = headers.respond_to?(:[]) ? (headers['location'] || headers['Location']) : nil
        return if value.blank?

        OpsLog.safe_path(URI.parse(value.to_s).path.presence || '/')
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
