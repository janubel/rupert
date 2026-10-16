# frozen_string_literal: true

class ReconciliationFollowUpsController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: %i[new create update]
  before_action do
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def index
    @status = %w[active open waiting closed overdue today all].include?(params[:status]) ? params[:status] : 'active'
    @source = ReconciliationDocument::SOURCES.excluding('rupert').include?(params[:source]) ? params[:source] : nil
    @owner_filter = %w[mine unassigned].include?(params[:owner]) ? params[:owner] : nil
    @category = ReconciliationFollowUp::CATEGORIES.key?(params[:category]) ? params[:category] : nil
    @evidence_filter = params[:evidence] == 'missing' ? 'missing' : nil
    scope = ReconciliationFollowUp.all
    if params[:original].present?
      @original = ReconciliationDocument.find(params[:original])
      scope = scope.merge(ReconciliationDocumentFollowUps.scope_for(@original))
    end
    scope = scope.where(source: @source) if @source
    scope = scope.where(owner_id: @owner_filter == 'mine' ? Current.user.id : nil) if @owner_filter
    scope = scope.where(category: @category) if @category
    scope = scope.where(document_id: nil) if @evidence_filter
    scope = scope.active if %w[active overdue today].include?(@status)
    scope = scope.where('due_on < ?', Date.current) if @status == 'overdue'
    scope = scope.where(due_on: Date.current) if @status == 'today'
    scope = scope.where(status: @status) if ReconciliationFollowUp::STATUSES.key?(@status)
    if params[:day].present?
      @day = ReconciliationEvidence.dates(params[:day], params[:day]).first
      scope = scope.covering(@day)
    end
    @open_count = ReconciliationFollowUp.active.count
    @overdue_count = ReconciliationFollowUp.active.where('due_on < ?', Date.current).count
    @today_count = ReconciliationFollowUp.active.where(due_on: Date.current).count
    @unassigned_count = ReconciliationFollowUp.active.where(owner_id: nil).count
    @missing_file_count = ReconciliationFollowUp.active.where(category: 'missing_report', document_id: nil).count
    @pagy, @follow_ups = pagy(scope.includes(:owner).order(Arel.sql("CASE WHEN status = 'closed' THEN 1 ELSE 0 END"), :due_on, :id), items: 25)
  rescue ReconciliationEvidence::Error
    redirect_to reconciliation_follow_ups_path, alert: 'Choose a valid business day.'
  end

  def overview
    @overview = ReconciliationAcrossDays.new(ending_on: params[:ending_on].presence || Date.yesterday.iso8601)
    @overdue_count = ReconciliationFollowUp.active.where('due_on < ?', Date.current).count
    @today_count = ReconciliationFollowUp.active.where(due_on: Date.current).count
    @next_follow_ups = ReconciliationFollowUp.active.includes(:owner).order(:due_on, :id).limit(4)
    @locations_by_id = Location.select(:id, :name).index_by(&:id)
  rescue ReconciliationEvidence::Error
    redirect_to overview_reconciliation_follow_ups_path, alert: 'Choose a valid ending business day.'
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
      redirect_to @follow_up, notice: 'Follow-up saved in Rupert. No email or message was sent.'
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
      destination = params[:return_to] == 'overdue' ? reconciliation_follow_ups_path(status: 'overdue') : @follow_up
      redirect_to destination, notice: 'Progress saved in Rupert. Earlier notes and assignments are retained. No email or message was sent.'
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
    # Keep a specifically reviewed original selectable even outside the recent list.
    [params[:evidence], @follow_up.document_id].compact.each do |id|
      next if @matching_documents.any? { |doc| doc.id.to_s == id.to_s }

      doc = ReconciliationDocument.select(:id, :tenant_id, :source, :kind, :filename, :metadata_json, :period_from, :period_to, :supersedes_id, :created_at).find_by(id: id)
      @matching_documents.unshift(doc) if @follow_up.document_matches?(doc)
    end
    if params[:evidence].present?
      @suggested_document_id = @matching_documents.find { |doc| doc.id.to_s == params[:evidence] }&.id
      @evidence_suggestion_missing = @suggested_document_id.nil?
    end
    @report_changed = @follow_up.report_digest.present? && @follow_up.report_digest != DailyMoneyReconciliation.new(day: @follow_up.period_from.iso8601).digest
  end
end
