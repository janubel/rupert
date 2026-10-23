# frozen_string_literal: true

module TeamChat
  # Runs keep their original request snapshot. Editing creates new work rather
  # than changing the question under a running worker or its approval receipts.
  module RequestRevision
    STOPPED = 'The request changed or was deleted. This reply was stopped.'

    def self.changed!(trigger, restart:)
      return [] unless trigger.person?

      # Fetch only executing work or unresolved approvals, never transcripts or
      # decided receipts. Pending review is still work the requester can withdraw.
      scope = Run.unscoped.where(tenant_id: trigger.tenant_id)
      pending = Approval.unscoped.where(tenant_id: trigger.tenant_id, state: 'proposed').select(:source_message_id)
      scope = scope.where(state: Run::ACTIVE).or(scope.where(message_id: pending))
      ids = scope.pluck(:id, :message_id, :request_context).filter_map do |id, reply_id, context|
        source = context['trigger_id'] || Message.unscoped.find_by(id: reply_id, tenant_id: trigger.tenant_id)&.meta&.dig('trigger_id')
        id if source == trigger.id || context['source_trigger_id'] == trigger.id
      end
      stopped = []
      Run.unscoped.where(tenant_id: trigger.tenant_id, id: ids).order(:id).each do |run|
        run.with_lock do
          if Run::ACTIVE.include?(run.state)
            run.terminalize!('cancelled', STOPPED, dismiss: true, actor: trigger.user)
            stopped << run.message
          elsif Approval.where(source_message_id: run.message_id, state: 'proposed').exists?
            run.message.with_lock { Actions.dismiss_pending!(run.message, reason: STOPPED, user: trigger.user) }
            stopped << run.message
          end
        end
      end
      return stopped unless restart && stopped.any? && !trigger.deleted?

      user = trigger.user
      return stopped unless user&.active? && TeamChat.allowed?(user) && user.can?('dashboard.read') && user.tenant&.status == 'active' && trigger.room.visible_to?(user)

      prior = stopped.flat_map { |reply| [reply.id, *Array(reply.run&.request_context&.fetch('prior_reply_ids', []))] }.uniq
      executed = Approval.unscoped.where(tenant_id: trigger.tenant_id, source_message_id: prior, state: 'done').distinct.pluck(:source_message_id)
      post = Post.new(room: trigger.room, user: user, body: trigger.body, parent_id: trigger.parent_id, prior_reply_ids: executed)
      quote = trigger.room.messages.visible.find_by(id: trigger.quote_id) if trigger.quote_id
      replies = post.replies_for(trigger, quote: quote)
      ActiveRecord.after_all_transactions_commit { replies.each { |reply| ReplyJob.perform_later(reply.id) } }
      stopped + replies
    end
  end
end
