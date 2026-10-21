# frozen_string_literal: true

# Ask Rupert, the in-app help chat. JSON endpoints behind the header panel.
# Everyone signed in (except employee-app accounts) may ask; what the assistant
# can look up is decided by that person's own permissions, never by this
# controller. Conversations are private to their owner.
class AskRupertController < AuthenticatedController
  before_action :require_available
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :load_conversation, only: %i[conversation destroy ask report]

  STARTERS = [
    { text: 'Where do I find today’s sales?', permission: 'sales.read' },
    { text: 'How do I count inventory?', permission: 'inventory.read' },
    { text: 'How do I close out the day?', permission: 'reports.read' },
    { text: 'How do I approve timesheets?', permission: 'timesheets.read' },
    { text: 'Where is my time clock?', permission: nil },
    { text: 'How do I switch to dark mode?', permission: nil }
  ].freeze
  REPORT_STARTER = 'Something looks wrong. How do I report it?'
  MESSAGES_SHOWN = 60

  # GET /ask_rupert — what the panel needs when it opens.
  def show
    return redirect_to(learning_index_path) unless request.format.json?

    conversation = AskRupert::Conversation.latest_for(Current.user)
    render json: state(conversation)
  end

  # POST /ask_rupert/conversations — New chat.
  def create_conversation
    conversation = AskRupert::Conversation.create!(user: Current.user)
    render json: state(conversation), status: :created
  end

  # GET /ask_rupert/conversations/:id — polled while a reply is being written.
  def conversation
    expire_stale(@conversation)
    render json: conversation_payload(@conversation)
  end

  def destroy
    @conversation.destroy
    ActivityLogger.log('ask_rupert_cleared', details: "conversation=#{@conversation.id}")
    head :no_content
  end

  # POST /ask_rupert/conversations/:id/messages
  def ask
    config = config_now
    text = AskRupert::Redactor.clean(params[:message])
    return render_error('Type a question first.', :unprocessable_entity) if text.blank?
    return render_error("Please keep it under #{config['max_message_chars']} characters.", :unprocessable_entity) if text.length > config['max_message_chars']

    assistant = nil
    decision = nil
    AskRupert::Usage.transaction do
      decision = AskRupert::Limits.new(Current.user, config: config).check
      next unless decision.allowed?

      assistant = start_turn(text)
    end
    return render_limited(decision) unless decision.allowed?

    AskRupertReplyJob.perform_later(assistant.id)
    render json: conversation_payload(@conversation), status: :accepted
  end

  # POST /ask_rupert/conversations/:id/report — the person pressed Send report.
  def report
    draft = draft_from_params
    feedback = AskRupert::Reporter.file!(user: Current.user, conversation: @conversation, kind: draft['kind'],
      summary: draft['summary'], details: draft['details'])
    mark_filed(feedback)
    render json: { ok: true, message: 'Thanks. Your report was sent to the Rupert team, with this chat attached.' }, status: :created
  rescue AskRupert::Reporter::Error => e
    render_error(e.message, :unprocessable_entity)
  end

  private

  def require_available
    return head :not_found unless AskRupert::Config.current.enabled?
    head :forbidden if Current.user.employee? || Current.tenant_id != Current.user.tenant_id
  end

  def config_now = @config_now ||= AskRupert::Config.current

  def load_conversation
    @conversation = AskRupert::Conversation.owned_by(Current.user).find_by(id: params[:id])
    render_error('That chat is gone. Start a new one.', :not_found) unless @conversation
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end

  def render_limited(decision)
    AskRupert::Usage.create!(user: Current.user, outcome: 'limited')
    response.headers['Retry-After'] = decision.retry_after.to_s
    render json: { error: decision.message, limited: decision.reason, retry_after: decision.retry_after }, status: :too_many_requests
  end

  # The user's question, the empty reply it will fill, and the usage row that
  # holds the one-in-flight and rate-limit counts.
  def start_turn(text)
    @conversation.update!(title: text.squish.first(60)) if @conversation.title.blank?
    @conversation.messages.create!(user: Current.user, role: 'user', content: text, page_path: page_path)
    AskRupert::Usage.create!(user: Current.user, outcome: 'pending')
    @conversation.touch_last_message!
    @conversation.messages.create!(user: Current.user, role: 'assistant', status: 'pending', page_path: page_path)
  end

  # Only a plain in-app path is kept; it is used to look up that page's guide.
  def page_path
    path = params[:page_path].to_s
    path if path.length <= 200 && path.match?(%r{\A/[\w\-/.]*\z}) && !path.include?('//')
  end

  def draft_from_params
    message = @conversation.messages.find_by(id: params[:message_id], role: 'assistant') if params[:message_id].present?
    base = message&.report_draft.is_a?(Hash) ? message.report_draft : {}
    @draft_message = message
    { 'kind' => params[:kind].presence || base['kind'], 'summary' => params[:summary].presence || base['summary'],
      'details' => params[:details].presence || base['details'] }
  end

  def mark_filed(feedback)
    return unless @draft_message&.report_draft.is_a?(Hash)

    @draft_message.update!(report_draft: @draft_message.report_draft.merge('filed' => true, 'report_id' => feedback.id))
  end

  def expire_stale(conversation)
    conversation.messages.pending.find_each do |message|
      next unless message.stale?

      message.update!(status: 'failed', content: AskRupert::ProviderError.friendly(:timeout))
      AskRupert::Usage.where(user_id: Current.user.id, outcome: 'pending').update_all(outcome: 'error')
    end
  end

  def state(conversation)
    config = config_now
    expire_stale(conversation) if conversation
    {
      disclosure: AskRupert::Providers.disclosure(config), mode: config.mode,
      limits: { count: config['rate_limit_count'], window_minutes: config['rate_limit_window_minutes'], max_chars: config['max_message_chars'] },
      starters: starters,
      conversation: conversation && conversation_payload(conversation)
    }
  end

  # Three things this person can really do, then how to report a problem.
  def starters
    STARTERS.select { |starter| starter[:permission].nil? || Current.user.can?(starter[:permission]) }.map { |starter| starter[:text] }.first(3) + [REPORT_STARTER]
  end

  def conversation_payload(conversation)
    messages = conversation.messages.order(:id).last(MESSAGES_SHOWN)
    { id: conversation.id, busy: messages.any?(&:pending?), messages: messages.map(&:as_payload) }
  end
end
