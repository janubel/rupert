# frozen_string_literal: true

module OpsLog
  # Turns framework instrumentation into events: what a controller action did (feeds the
  # request line and the permission/validation/upload events), job runs, retries and
  # discards, Rails.error reports, and throttled requests. Also silences the default Rails
  # lines these replace when a structured format is on.
  module Subscribers
    # Rails' own request and job lines, replaced by the events above in structured formats.
    module QuietLines
      def self.build(subscriber)
        Module.new do
          (subscriber.log_levels.keys - %i[unpermitted_parameters]).each do |event|
            define_method(event) { |payload| OpsLog.single_line? ? nil : super(payload) }
          end
        end
      end
    end

    # Reads the finished action and leaves its facts for the request line.
    module ProcessAction
      IGNORED_PARAMS = %w[controller action authenticity_token utf8 commit _method format].freeze

      class << self
        def call(event)
          payload = event.payload
          request = payload[:request]
          return unless request

          ops = payload[:ops] || {}
          data = {
            db_ms: payload[:db_runtime]&.round(1), view_ms: payload[:view_runtime]&.round(1), allocations: event.allocations,
            format: payload[:format]&.to_s, bytes: body_bytes(payload[:response]),
            user_id: ops[:user_id], tenant_id: ops[:tenant_id], role: ops[:role]
          }
          data[:params_keys] = param_names(payload[:params]) unless request.get? || request.head?
          data[:error] = OpsLog.error_fields(payload[:exception_object]) if payload[:exception_object]
          data[:explained] = side_events(request, payload, ops)
          request.env[OpsLog::RequestLine::ENV_KEY] = data.compact
        rescue StandardError
          nil
        end

        private

        # Emits the events that explain a 4xx. Returns true when it wrote one.
        def side_events(request, payload, ops)
          named = payload[:params] || {}
          where = { controller: named['controller'], action: named['action'], method: payload[:method], status: payload[:status] }
          explained = false
          if ops[:denied]
            OpsLog.event('permission_denied', level: :warn, **where, **ops[:denied], user_id: ops[:user_id], tenant_id: ops[:tenant_id], role: ops[:role])
            explained = true
          end
          Array(ops[:validation]).each do |failure|
            OpsLog.event('validation_failed', level: :warn, **where, **failure, user_id: ops[:user_id], tenant_id: ops[:tenant_id])
            explained = true
          end
          if ops[:uploads].present?
            outcome = payload[:status].to_i >= 400 || ops[:validation].present? ? 'rejected' : 'accepted'
            OpsLog.event('upload', level: outcome == 'rejected' ? :warn : :info, **where.except(:method), files: ops[:uploads], outcome: outcome,
              user_id: ops[:user_id], tenant_id: ops[:tenant_id], persist: false)
          end
          explained
        end

        def body_bytes(response)
          return unless response

          length = response.headers['content-length']
          return length.to_i if length.present?

          body = response.body if !response.respond_to?(:sending_file?) || !response.sending_file?
          body.bytesize if body.is_a?(String)
        end

        # Parameter names only, numeric keys collapsed, so a failed POST shows what was sent.
        def param_names(params, prefix = nil, depth = 0, out = [])
          return out if depth > 3 || out.size >= 30

          params.each do |key, value|
            name = key.to_s
            next if prefix.nil? && IGNORED_PARAMS.include?(name)

            name = '#' if name.match?(/\A\d+\z/)
            path = [prefix, name].compact.join('.').first(60)
            if value.is_a?(Hash) || value.is_a?(ActionController::Parameters)
              param_names(value, path, depth + 1, out)
            else
              out << path
            end
          end
          out.uniq
        end
      end
    end

    # Job runs, retries and discards.
    module Jobs
      class << self
        def perform(event)
          payload = event.payload
          job = payload[:job]
          error = payload[:exception_object]
          duration = event.duration.round(1)
          outcome = error ? 'failed' : (payload[:aborted] ? 'aborted' : 'ok')
          fields = { job_class: job.class.name, queue: job.queue_name, job_id: job.job_id, executions: job.executions,
                     duration_ms: duration, db_ms: payload[:db_runtime]&.round(1), outcome: outcome, tenant_id: Current.tenant_id }
          fields.merge!(OpsLog.error_fields(error)) if error
          return unless OpsLog.single_line? || error

          if outcome == 'ok' && duration < OpsLog.quiet_job_ms
            Noise.count("job #{job.class.name} ok", duration)
            OpsLog.event('job', level: :debug, persist: false, **fields)
          else
            OpsLog.event('job', level: error ? :error : :info, **fields)
          end
        end

        def retry_scheduled(event)
          retry_event('job_retry', :warn, event)
        end

        def retry_stopped(event)
          retry_event('job_retry_exhausted', :error, event)
        end

        def discarded(event)
          retry_event('job_discarded', :warn, event)
        end

        private

        def retry_event(name, level, event)
          job = event.payload[:job]
          fields = { job_class: job.class.name, queue: job.queue_name, job_id: job.job_id, executions: job.executions }
          fields[:wait_s] = event.payload[:wait].to_i if event.payload[:wait]
          OpsLog.event(name, level: level, **fields, **OpsLog.error_fields(event.payload[:error]))
        end
      end
    end

    # Rails.error reports: rescued and unhandled exceptions from anywhere.
    class ErrorReporter
      def report(error, handled:, severity:, context:, source: nil)
        # An unhandled request error is already persisted by its request line.
        OpsLog.event('exception', level: handled ? :warn : :error, persist: source != 'application.action_dispatch', **OpsLog.error_fields(error, frames: 12),
          handled: handled, severity: severity, source: source, context_keys: context.keys.map(&:to_s).first(8), **OpsLog.actor_fields)
      end
    end

    class << self
      def install!
        return if @installed

        @installed = true
        notifications = ActiveSupport::Notifications
        notifications.subscribe('process_action.action_controller') { |event| ProcessAction.call(event) }
        notifications.subscribe('perform.active_job') { |event| Jobs.perform(event) }
        notifications.subscribe('enqueue_retry.active_job') { |event| Jobs.retry_scheduled(event) }
        notifications.subscribe('retry_stopped.active_job') { |event| Jobs.retry_stopped(event) }
        notifications.subscribe('discard.active_job') { |event| Jobs.discarded(event) }
        notifications.subscribe('throttle.rack_attack') { |*, payload| throttled(payload[:request]) }
        Rails.error.subscribe(ErrorReporter.new)
        quiet_default_lines
        at_exit { OpsLog::Noise.flush }
      end

      private

      def throttled(request)
        OpsLog.event('rate_limited', level: :warn, rule: request.env['rack.attack.matched'], method: request.request_method,
          path: OpsLog.safe_path(request.path), ip: request.ip, reason: request.env['rack.attack.matched'])
      end

      def quiet_default_lines
        require 'action_controller/log_subscriber'
        require 'active_job/log_subscriber'
        require 'action_view/log_subscriber'
        ActionController::LogSubscriber.prepend(QuietLines.build(ActionController::LogSubscriber))
        ActiveJob::LogSubscriber.prepend(QuietLines.build(ActiveJob::LogSubscriber))
        ActionView::LogSubscriber.prepend(QuietLines.build(ActionView::LogSubscriber))
      end
    end
  end
end
