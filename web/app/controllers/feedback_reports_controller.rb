# frozen_string_literal: true

# The ladybug: any signed-in staff member can report a bug, ask for something
# or ask a question from any page. Staff see their own reports and each one's
# status; administrators also see the attachments (screenshot, page snapshot,
# logs, queries). Everything a report holds is untrusted text, shown escaped.
class FeedbackReportsController < AuthenticatedController
  MAX_BODY_BYTES = 4.megabytes

  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :load_report, only: %i[show screenshot]
  before_action :require_attachment_access, only: :screenshot

  def index
    @reports = AgentFeedback.reported_by(Current.user).newest_first.limit(100)
  end

  def create
    return render(json: { error: 'The report is too large. Try again without the screenshot.' }, status: :content_too_large) if request.content_length.to_i > MAX_BODY_BYTES

    report = FeedbackReport.submit!(user: Current.user, params: report_params, request: request, trace_key: request.env[RequestTrace::KEY])
    render json: { id: report.id, status: report.status, status_label: report.status_label, url: feedback_report_path(report),
                   message: "Thank you. Report ##{report.id} was sent to the team." }, status: :created
  rescue FeedbackReport::Error => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def show
    @attachments = FeedbackAttachment.viewable_by?(Current.user) ? @report.attachments.order(:id).to_a : []
  end

  def screenshot
    attachment = @report.attachments.find_by!(kind: 'screenshot')
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
    send_data attachment.binary_body, type: attachment.content_type, disposition: 'inline'
  end

  private

  def report_params
    params.require(:feedback_report).permit(:kind, :severity, :description, :page_url, :page_request_id, :client, :js_errors,
      :dom_snapshot, :screenshot)
  end

  def load_report
    scope = FeedbackAttachment.viewable_by?(Current.user) ? AgentFeedback.all : AgentFeedback.reported_by(Current.user)
    @report = scope.find(params[:id])
  end

  def require_attachment_access
    head :not_found unless FeedbackAttachment.viewable_by?(Current.user)
  end
end
