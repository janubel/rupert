# frozen_string_literal: true

module TeamChat
  # An explicit tenant/claim context also works inside RubyLLM's generation thread.
  class TelemetryRecorder
    TOKEN_FIELDS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens].freeze

    def self.count(value) = (value if value.is_a?(Integer) && value >= 0)

    def self.cost(value)
      value if value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def initialize(run, token, stage: 'answer')
      @run_id, @tenant_id, @token, @stage = run.id, run.tenant_id, token, stage
    end

    def record(kind, outcome:, facts: {}, started_at: Time.current, duration_ms: nil)
      Telemetry.unscoped.create!(run_id: @run_id, tenant_id: @tenant_id, claim_token: @token,
        kind: kind, stage: @stage, outcome: outcome, started_at: started_at,
        finished_at: Time.current, duration_ms: duration_ms, facts: facts)
    end

    def measure(kind, facts: {})
      row = Telemetry.unscoped.create!(run_id: @run_id, tenant_id: @tenant_id, claim_token: @token,
        kind: kind, stage: @stage, started_at: Time.current, facts: facts)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield row
      outcome = 'succeeded'
      result
    rescue Exception => e # cancellation must leave a receipt too
      outcome = e.is_a?(Run::Stopped) ? 'cancelled' : 'failed'
      row&.update!(facts: row.facts.merge('error_class' => e.class.name,
        'error_kind' => (e.kind.to_s if e.respond_to?(:kind))).compact)
      raise
    ensure
      if row
        outcome = row.reload.facts.fetch('result_outcome', outcome)
        if kind == 'execution'
          state = Run.unscoped.find(@run_id).state
          outcome = state unless Run::ACTIVE.include?(state)
        end
        # A recovered claimant may already have marked this span interrupted.
        Telemetry.unscoped.where(id: row.id, outcome: 'running').update_all(outcome: outcome || 'interrupted',
          finished_at: Time.current, duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end
    end

    def context_key = @context_key ||= :"chat_telemetry_#{object_id}"

    def instrument(name, payload)
      if name == 'usage.ruby_llm'
        tokens = payload[:tokens]
        facts = tokens.to_h.slice(*TOKEN_FIELDS).transform_values { |value| self.class.count(value) }.stringify_keys
        cost = self.class.cost(tokens.reported_cost)
        facts.merge!('cost_usd' => cost, 'cost_source' => cost.nil? ? 'unknown' : 'provider_reported',
          'provider' => payload[:provider].to_s, 'model' => payload[:model].to_s,
          'operation' => payload[:operation].to_s, 'timing' => 'completion_only')
        request = Thread.current[context_key]
        request[:attempts] += 1 if request
        facts['attempt'] = request[:attempts] if request
        facts['request_id'] = request[:id] if request
        record('provider_attempt', outcome: payload[:status].to_s, facts: facts)
      elsif name == 'chat.ruby_llm'
        measure('generation') do |row|
          previous = Thread.current[context_key]
          context = { id: row.id, attempts: 0 }
          Thread.current[context_key] = context
          begin
            yield payload
          ensure
            row.update!(facts: row.facts.merge('attempts' => context[:attempts]))
            Thread.current[context_key] = previous
          end
        end
      elsif name == 'request.ruby_llm'
        measure('inference') do |row|
          yield payload
        ensure
          row.update!(facts: row.facts.merge('http_status' => payload[:status]))
        end
      elsif block_given?
        yield payload
      end
    end
  end
end
