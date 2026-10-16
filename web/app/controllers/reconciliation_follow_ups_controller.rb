# frozen_string_literal: true

class ReconciliationFollowUpsController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: %i[new create update]
  before_action do
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def index
    @status = %w[active open waiting closed overdue all].include?(params[:status]) ? params[:status] : 'active'
    @source = ReconciliationDocument::SOURCES.excluding('rupert').include?(params[:source]) ? params[:source] : nil
    @owner_filter = %w[mine unassigned].include?(params[:owner]) ? params[:owner] : nil
    scope = ReconciliationFollowUp.all
    scope = scope.where(source: @source) if @source
    scope = scope.where(owner_id: @owner_filter == 'mine' ? Current.user.id : nil) if @owner_filter
    scope = scope.active if %w[active overdue].include?(@status)
    scope = scope.where('due_on < ?', Date.current) if @status == 'overdue'
    scope = scope.where(status: @status) if ReconciliationFollowUp::STATUSES.key?(@status)
    if params[:day].present?
      @day = ReconciliationEvidence.dates(params[:day], params[:day]).first
      scope = scope.covering(@day)
    end
    @open_count = ReconciliationFollowUp.active.count
    @overdue_count = ReconciliationFollowUp.active.where('due_on < ?', Date.current).count
    @pagy, @follow_ups = pagy(scope.includes(:owner).order(Arel.sql("CASE WHEN status = 'closed' THEN 1 ELSE 0 END"), :due_on, :id), items: 25)
  rescue ReconciliationEvidence::Error
    redirect_to reconciliation_follow_ups_path, alert: 'Choose a valid business day.'
  end

  def new
    values = params.permit(:category, :source, :document_kind, :period_from, :period_to, :currency, :location_id, :metric, :title).to_h
    @follow_up = ReconciliationFollowUp.new({ category: 'missing_report', source: 'other', document_kind: 'source_export',
      period_from: Date.current, period_to: Date.current, due_on: Date.current + 1, owner_id: Current.user.tenant_id == Current.tenant_id ? Current.user.id : nil, submission_key: SecureRandom.uuid }.merge(values))
    form_options
  end

  def create
    values = params.require(:follow_up).permit(:category, :source, :document_kind, :period_from, :period_to, :currency, :location_id, :metric,
      :title, :notes, :due_on, :owner_id, :submission_key)
    @follow_up = ReconciliationFollowUp.find_by(submission_key: values[:submission_key]) if values[:submission_key].present?
    return redirect_to(@follow_up, notice: 'This request is already saved. Open it to record another update.') if @follow_up

    @follow_up = ReconciliationFollowUp.new(values)
    @follow_up.created_by = Current.user
    if @follow_up.category == 'difference' && @follow_up.period_from
      @follow_up.report_digest = DailyMoneyReconciliation.new(day: @follow_up.period_from.iso8601).digest
    end
    if @follow_up.save
      redirect_to @follow_up, notice: 'Follow-up saved in Rupert.'
    else
      form_options
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to ReconciliationFollowUp.find_by!(submission_key: values[:submission_key]), notice: 'This request is already saved.'
  end

  def show
    @follow_up = ReconciliationFollowUp.find(params[:id])
    show_options
  end

  def update
    @follow_up = ReconciliationFollowUp.find(params[:id])
    values = params.require(:follow_up).permit(:title, :status, :due_on, :owner_id, :notes, :document_id, :lock_version)
    unless values[:lock_version].to_s.match?(/\A\d+\z/) && values[:notes].present?
      @entered_values = values.to_h
      @follow_up.errors.add(:base, 'Enter a progress note or closing reason and reload an outdated form.')
      show_options
      return render :show, status: :unprocessable_entity
    end
    if @follow_up.update(values)
      redirect_to @follow_up, notice: 'Follow-up updated. Earlier notes and assignments are retained.'
    else
      @entered_values = values.to_h
      messages = @follow_up.errors.full_messages
      @follow_up.reload
      messages.each { |message| @follow_up.errors.add(:base, message) }
      show_options
      render :show, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError
    @entered_values = values.to_h
    @follow_up.reload
    @follow_up.errors.add(:base, 'Someone updated this follow-up. Your text is preserved below; compare the latest history before saving again.')
    show_options
    render :show, status: :unprocessable_entity
  end

  private

  def form_options
    @owners = User.active.where(tenant_id: Current.tenant_id).order(:name, :id).select { |user| user.can?('reports.read') }
    @locations = Location.select(:id, :name, :source).order(:name).to_a
  end

  def show_options
    form_options
    @events_pagy, @events = pagy(@follow_up.events.order(id: :desc), items: 15, page_param: :history_page)
    @matching_documents = @follow_up.matching_documents
    @report_changed = @follow_up.report_digest.present? && @follow_up.report_digest != DailyMoneyReconciliation.new(day: @follow_up.period_from.iso8601).digest
  end
end
