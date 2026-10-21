# frozen_string_literal: true

require 'csv'

# Review page for feedback sent by external AI assistants over MCP
# (submit_feedback) and the automatic per-tool struggle counters. Settings
# readers can view; settings writers triage (status + owner notes).
# Everything an assistant wrote is untrusted text: it is rendered escaped and
# exported with spreadsheet-formula protection, never interpreted.
class AgentFeedbacksController < AuthenticatedController
  before_action -> { authorize(:module, :settings_read?) }
  before_action -> { authorize(:module, :settings_write?) }, only: :update
  before_action -> { response.headers['Cache-Control'] = 'no-store' }

  CSV_HEADERS = ['ID', 'Submitted', 'Kind', 'Severity', 'Status', 'Summary', 'Details', 'Related tool', 'Related page/report',
                 'Assistant', 'Model', 'Token', 'Owner notes', 'Triaged at'].freeze
  CSV_LIMIT = 5000

  def index
    @filters = filter_params
    scope = filtered(AgentFeedback.includes(:api_access_token, :user, :triaged_by))
    @counts = { kind: AgentFeedback.group(:kind).count, status: AgentFeedback.group(:status).count,
                severity: AgentFeedback.group(:severity).count }
    @tools = AgentFeedback.where.not(related_tool: [nil, '']).distinct.order(:related_tool).limit(100).pluck(:related_tool)
    @issues = AgentToolIssue.order(last_seen_at: :desc).limit(100).to_a
    @issue_totals = AgentToolIssue.group(:tool_name).sum(:occurrences).sort_by { |_tool, count| -count }
    respond_to do |format|
      format.html { @pagy, @feedbacks = pagy(scope.newest_first, items: 50) }
      format.csv do
        log_export('AI assistant feedback CSV', @filters.compact_blank.map { |key, value| "#{key}=#{value}" }.join(' ').presence)
        send_data(csv(scope.newest_first.limit(CSV_LIMIT)), filename: "ai-feedback-#{Date.current.iso8601}.csv", type: 'text/csv')
      end
    end
  end

  def update
    feedback = AgentFeedback.find(params[:id])
    attributes = params.require(:agent_feedback).permit(:status, :owner_notes)
    feedback.assign_attributes(status: attributes[:status].presence || feedback.status,
      owner_notes: AgentFeedback.clean(attributes[:owner_notes], AgentFeedback::NOTES_MAX, multiline: true))
    if feedback.status_changed? || feedback.owner_notes_changed?
      feedback.triaged_by = Current.user
      feedback.triaged_at = Time.current
    end
    if feedback.save
      ActivityLogger.log('agent_feedback_triaged', subject: feedback, details: "status=#{feedback.status}")
      redirect_to agent_feedbacks_path(filter_params.compact_blank), notice: "Feedback ##{feedback.id} updated."
    else
      redirect_to agent_feedbacks_path(filter_params.compact_blank), alert: feedback.errors.full_messages.to_sentence
    end
  end

  private

  def filter_params
    {
      kind: allowed(params[:kind], AgentFeedback::KINDS.keys),
      status: allowed(params[:status], AgentFeedback::STATUSES.keys + ['open']),
      severity: allowed(params[:severity], AgentFeedback::SEVERITIES),
      tool: params[:tool].to_s.strip.first(100).presence
    }
  end

  def allowed(value, list)
    list.include?(value.to_s) ? value.to_s : nil
  end

  def filtered(scope)
    scope = scope.where(kind: @filters[:kind]) if @filters[:kind]
    scope = @filters[:status] == 'open' ? scope.where(status: %w[new triaged planned]) : scope.where(status: @filters[:status]) if @filters[:status]
    scope = scope.where(severity: @filters[:severity]) if @filters[:severity]
    scope = scope.where(related_tool: @filters[:tool]) if @filters[:tool]
    scope
  end

  def csv(scope)
    CSV.generate do |rows|
      rows << CSV_HEADERS
      scope.each do |feedback|
        rows << [feedback.id, feedback.created_at&.iso8601, feedback.kind, feedback.severity, feedback.status, feedback.summary,
                 feedback.details, feedback.related_tool, feedback.related_reference, feedback.agent_name, feedback.agent_model,
                 feedback.api_access_token&.name, feedback.owner_notes, feedback.triaged_at&.iso8601].map { |cell| csv_safe(cell) }
      end
    end
  end

  # Untrusted text must not become a spreadsheet formula when opened.
  def csv_safe(value)
    value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value
  end
end
