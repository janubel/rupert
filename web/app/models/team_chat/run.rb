# frozen_string_literal: true

module TeamChat
  # Private execution state; never serialized into the public room payload.
  class Run < ApplicationRecord
    self.table_name = 'chat_runs'
    include TenantScoped

    attr_readonly :request_context

    LEASE = 30.seconds
    MAX_ATTEMPTS = 3
    ACTIVE = %w[queued running].freeze
    STATES = (ACTIVE + %w[succeeded failed cancelled expired]).freeze
    class Stopped < StandardError; end

    belongs_to :message, class_name: 'TeamChat::Message'
    validates :state, inclusion: { in: STATES }
    validates :deadline_at, presence: true

    def self.for_reply!(reply)
      unscoped.create_or_find_by!(message_id: reply.id) do |run|
        run.tenant_id = reply.tenant_id
        trigger = Message.unscoped.find_by(id: reply.meta.to_h['trigger_id'], room_id: reply.room_id, tenant_id: reply.tenant_id)
        if trigger&.person?
          run.request_context = { 'requester_id' => trigger.user_id, 'requester_name' => trigger.user&.display_name,
                                  'trigger_id' => trigger.id, 'last_chat' => trigger.body, 'requested_at' => (reply.meta.to_h['source_requested_at'] || (trigger.edited_at || trigger.created_at).iso8601(6)),
                                  'parent_id' => trigger.parent_id, 'request_revision' => trigger.request_revision, 'permissions_signature' => trigger.user&.permissions_signature,
                                  'source_room_id' => reply.meta.to_h['source_room_id'] }
          %w[source_trigger_id source_request_revision source_parent_id prior_reply_ids].each do |key|
            run.request_context[key] = reply.meta[key] if reply.meta.to_h.key?(key)
          end
        end
        run.deadline_at = reply.created_at + (reply.local_agent ? 5.minutes : 2.minutes)
      end
    end

    # A single conditional UPDATE is the claim; a prior read is not ownership.
    def request_matches?(trigger)
      context = request_context.to_h
      return false unless matches_request?(trigger, room_id: message.room_id, parent_id: context['parent_id'], revision: context.fetch('request_revision', 0))
      return true unless context['source_room_id']
      return false unless context['source_trigger_id']

      source = Message.unscoped.find_by(id: context['source_trigger_id'], tenant_id: tenant_id)
      matches_request?(source, room_id: context['source_room_id'], parent_id: context['source_parent_id'], revision: context.fetch('source_request_revision', 0))
    end

    def matches_request?(trigger, room_id:, parent_id:, revision:)
      context = request_context.to_h
      trigger&.person? && !trigger.deleted? && trigger.tenant_id == tenant_id &&
        trigger.room_id == room_id && trigger.user_id == context['requester_id'] &&
        trigger.parent_id == parent_id && trigger.body == context['last_chat'] && trigger.request_revision == revision &&
        (trigger.edited_at.nil? || trigger.edited_at <= created_at)
    end

    def claim!
      expire! if deadline_at <= Time.current
      token = SecureRandom.uuid
      now = Time.current
      self.class.transaction do
        claimed = self.class.unscoped.where(id: id, state: ACTIVE).where('deadline_at > ? AND attempts < ?', now, MAX_ATTEMPTS)
                      .where('state = ? OR lease_until <= ?', 'queued', now)
                      .update_all(['state = ?, owner_token = ?, lease_until = ?, heartbeat_at = ?, attempts = attempts + 1, updated_at = ?',
                        'running', token, now + LEASE, now, now])
        if claimed == 1
          Telemetry.unscoped.where(run_id: id, outcome: 'running').update_all(outcome: 'interrupted', finished_at: now)
          TelemetryRecorder.new(self, token).record('claim', outcome: 'succeeded',
            facts: { 'queue_ms' => [(now - created_at) * 1000, 0].max.round, 'attempt' => reload.attempts })
          token
        end
      end
    end

    def cancel!(user: nil)
      with_lock do
        terminalize!('cancelled', 'Stopped.', dismiss: true, actor: user) if ACTIVE.include?(state)
      end
    end

    def expire!
      with_lock do
        terminalize!('expired', 'This reply reached its time limit. Please try a narrower question.', dismiss: true) if ACTIVE.include?(state) && deadline_at <= Time.current
      end
    end

    def terminalize!(status, body, dismiss: false, actor: nil)
      message.with_lock do
        attrs = { status: 'failed', activity: nil, body: body }
        Actions.dismiss_pending!(message, reason: body, user: actor) if dismiss
        message.update!(attrs)
      end
      update!(state: status, owner_token: nil, lease_until: nil)
      Telemetry.unscoped.where(run_id: id, outcome: 'running').update_all(outcome: 'interrupted', finished_at: Time.current)
    end
  end
end
