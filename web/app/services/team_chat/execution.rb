# frozen_string_literal: true

module TeamChat
  # Fences every checkpoint, proposal and public write. No transaction spans a
  # model request or a read tool. Proposal + replay receipt commit together.
  class Execution
    AccessChanged = Class.new(Run::Stopped)
    ACCESS_CHANGED = 'Access changed. Please ask Rupert again in your private room.'

    attr_reader :run, :token
    attr_accessor :chat

    def initialize(run, token)
      @run = run
      @token = token
    end

    def check!
      raise Run::Stopped, 'Wrong tenant context' unless Current.tenant_id == run.tenant_id

      run.reload
      run.expire! if run.deadline_at <= Time.current
      raise Run::Stopped, 'Run no longer owned' unless run.state == 'running' && run.owner_token == token && run.lease_until > Time.current

      if run.message.deleted?
        run.cancel!
        raise Run::Stopped, 'Reply deleted'
      end
      check_access!
      true
    end

    # Always use fresh records: User memoizes effective permissions, and a
    # recovered transcript may contain results obtained before access changed.
    def check_access!
      message = run.message.reload
      context = run.request_context.to_h
      user = User.find_by(id: context['requester_id'], tenant_id: run.tenant_id)
      room = Room.find_by(id: message.room_id, tenant_id: run.tenant_id)
      source = context['source_room_id'] && Room.find_by(id: context['source_room_id'], tenant_id: run.tenant_id)
      valid = Current.tenant_id == run.tenant_id && user && TeamChat.allowed?(user) && user.can?('dashboard.read') &&
        user.tenant&.status == 'active' && room&.visible_to?(user) &&
        context['permissions_signature'].present? && context['permissions_signature'] == user.permissions_signature &&
        message.meta.to_h['asked_by'] == context['requester_id'] &&
        message.meta.to_h['trigger_id'] == context['trigger_id'] &&
        (!context['source_room_id'] || source&.visible_to?(user))
      return if valid

      stop_for_access_change!
      raise AccessChanged, 'Access changed'
    end

    def private_delivery!
      room = run.message.room.reload
      return if room.direct? && room.created_by_id == run.request_context['requester_id']

      stop_for_access_change!
      raise AccessChanged, 'Business answers require a private Rupert room'
    end

    def remaining
      check!
      [run.deadline_at - Time.current, 0.01].max
    end

    def locked
      run.with_lock do
        check!
        yield
      end
    rescue AccessChanged
      # check! may run inside this transaction. Persist cancellation after its
      # rollback as well, so a rejected stream cannot leave a recoverable run.
      stop_for_access_change!
      raise
    end

    def stop_for_access_change!
      run.with_lock do
        # A slow access check from a superseded worker cannot cancel its successor.
        run.terminalize!('cancelled', ACCESS_CHANGED, dismiss: true) if run.state == 'running' && run.owner_token == token
      end
    end

    def pin_configuration!(config)
      identity = { 'engine' => config.engine, 'model' => config.model, 'endpoint' => config.api_base }
      locked do
        raise 'The model route changed during recovery' if run.configuration.present? && run.configuration != identity

        run.update!(configuration: identity) if run.configuration.blank?
      end
    end

    def checkpoint!(chat)
      locked { run.update!(transcript: chat.messages.map(&:to_h), steps: run.steps + 1) }
    end

    def write_reply!(attributes, terminal: nil)
      locked do
        private_delivery!
        run.message.update!(attributes)
        run.update!(state: terminal, owner_token: nil, lease_until: nil) if terminal
      end
    end

    def tool!(id, name, arguments, write: false)
      check!
      private_delivery!
      raise 'Tool call has no durable ID' if id.blank?

      cached = run.tool_results.find { |entry| entry['id'] == id }
      if cached
        raise 'Tool call changed during replay' unless cached['name'] == name && cached['arguments'] == arguments.deep_stringify_keys

        return cached['result']
      end
      result = nil
      save = lambda do
        result = yield
        run.update!(tool_results: run.tool_results + [{ 'id' => id, 'name' => name, 'arguments' => arguments.deep_stringify_keys, 'result' => result }])
      end
      if write
        locked { save.call }
      else
        result = yield
        locked do
          run.update!(tool_results: run.tool_results + [{ 'id' => id, 'name' => name, 'arguments' => arguments.deep_stringify_keys, 'result' => result }])
        end
      end
      result
    end

    # Only generation runs in this thread: it cannot invoke application tools
    # or write replies. We can stop silent network I/O without interrupting a
    # database transaction, and release the chat worker promptly on Stop.
    def generate(chat)
      events = Queue.new
      request = Thread.new do
        chat.generate { |chunk| events << [:chunk, chunk] }
        events << [:done, nil]
      rescue Exception => error
        events << [:error, error]
      end
      loop do
        check!
        event = events.pop(timeout: 0.1)
        next unless event

        kind, value = event
        raise value if kind == :error
        break if kind == :done

        yield value
      end
    ensure
      if request
        chat.cancel if request.alive?
        request.kill if request.alive?
        request.join
      end
    end

    def start_watch
      @stop_watch = false
      @watch = Thread.new do
        last_heartbeat = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        until @stop_watch
          sleep 0.25
          next if @stop_watch

          begin
            Run.connection_pool.with_connection do
              current = Run.unscoped.find(run.id)
              if current.state != 'running' || current.owner_token != token || current.deadline_at <= Time.current || (current.lease_until.nil? || current.lease_until <= Time.current)
                chat&.cancel
                break
              end
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if now - last_heartbeat >= 5
                Run.unscoped.where(id: run.id, state: 'running', owner_token: token).where('lease_until > ?', Time.current)
                   .update_all(lease_until: Time.current + Run::LEASE, heartbeat_at: Time.current)
                last_heartbeat = now
              end
            end
          rescue ActiveRecord::ActiveRecordError
            # Failure to renew never grants ownership: the next guarded write
            # rejects an expired lease, even if the request eventually returns.
            chat&.cancel
            break
          end
        end
      end
    end

    def stop_watch
      @stop_watch = true
      @watch&.join
    end
  end
end
