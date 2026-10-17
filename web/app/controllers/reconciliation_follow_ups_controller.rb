# frozen_string_literal: true

class ReconciliationFollowUpsController < AuthenticatedController
  include ReconciliationCloseContext
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: %i[new create update]
  before_action do
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def index
    selection = ReconciliationFollowUpQueue.new(params.permit(*ReconciliationFollowUpQueue::KEYS).to_h)
    @status, @source, @owner_filter = selection.status, selection.source, selection.owner
    @category, @evidence_filter = selection.category, selection.evidence
    @original, @day = selection.original, selection.day
    @queue_filters = selection.filters
    scope = ReconciliationFollowUp.all
    scope = scope.merge(ReconciliationDocumentFollowUps.scope_for(@original)) if @original
    scope = scope.where(source: @source) if @source
    scope = scope.where(owner_id: @owner_filter == 'mine' ? Current.user.id : nil) if @owner_filter
    scope = scope.where(category: @category) if @category
    scope = scope.where(document_id: nil) if @evidence_filter
    scope = scope.active if %w[active overdue today].include?(@status)
    scope = scope.where('due_on < ?', Date.current) if @status == 'overdue'
    scope = scope.where(due_on: Date.current) if @status == 'today'
    scope = scope.where(status: @status) if ReconciliationFollowUp::STATUSES.key?(@status)
    scope = scope.covering(@day) if @day
    active_view = scope.active
    overdue_view = active_view.where('due_on < ?', Date.current)
    missing_view = active_view.where(category: 'missing_report', document_id: nil)
    @view_overdue_count = overdue_view.count
    @view_missing_count = missing_view.count
    @view_next_overdue = overdue_view.includes(:owner).order(:due_on, :id).first
    @view_next_missing = missing_view.includes(:owner).order(:due_on, :id).first
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
    @focus = ReconciliationAcrossDays::FOCUS.key?(params[:focus]) ? params[:focus] : 'all'
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
    load_close_context
    form_options
  end

  def create
    values = params.require(:follow_up).permit(:category, :source, :document_kind, :period_from, :period_to, :currency, :location_id, :metric,
      :title, :notes, :due_on, :owner_id, :submission_key)
    @follow_up = ReconciliationFollowUp.find_by(submission_key: values[:submission_key]) if values[:submission_key].present?
    if @follow_up
      load_close_context
      return redirect_to(reconciliation_follow_up_path(@follow_up, close_day: @close_day&.iso8601), notice: 'This request is already saved. Open it to record another update.')
    end

    @follow_up = ReconciliationFollowUp.new(values)
    @follow_up.created_by = Current.user
    load_close_context
    if @follow_up.category == 'difference' && @follow_up.period_from
      @follow_up.report_digest = DailyMoneyReconciliation.new(day: @follow_up.period_from.iso8601).digest
    end
    if @follow_up.save
      ActivityLogger.log('reconciliation_follow_up_created', subject: @follow_up, details: "#{@follow_up.category}: #{@follow_up.period_from}..#{@follow_up.period_to}")
      redirect_to reconciliation_follow_up_path(@follow_up, close_day: @close_day&.iso8601), notice: 'Follow-up saved in Rupert. No email or message was sent.'
    else
      form_options
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    @follow_up = ReconciliationFollowUp.find_by!(submission_key: values[:submission_key])
    load_close_context
    redirect_to reconciliation_follow_up_path(@follow_up, close_day: @close_day&.iso8601), notice: 'This request is already saved.'
  end

  def show
    @follow_up = ReconciliationFollowUp.find(params[:id])
    show_options
  end

  def update
    @follow_up = ReconciliationFollowUp.find(params[:id])
    load_close_context
    load_return_queue
    values = params.require(:follow_up).permit(:title, :status, :due_on, :owner_id, :notes, :document_id, :lock_version)
    unless values[:lock_version].to_s.match?(/\A\d+\z/) && values[:notes].present?
      @entered_values = values.to_h
      @follow_up.errors.add(:base, 'Enter a progress note or closing reason and reload an outdated form.')
      show_options
      return render :show, status: :unprocessable_entity
    end
    if @follow_up.update(values)
      ActivityLogger.log('reconciliation_follow_up_updated', subject: @follow_up, details: "status #{@follow_up.status}")
      destination = if params[:return_to] == 'close' && @close_day
        financial_close_path(day: @close_day.iso8601, anchor: 'close-follow-ups')
      elsif params[:return_to] == 'next_overdue'
        @next_overdue = next_overdue
        next_day = @close_day if @next_overdue && @close_day&.between?(@next_overdue.period_from, @next_overdue.period_to)
        @next_overdue ? reconciliation_follow_up_path(@next_overdue, close_day: next_day&.iso8601, anchor: 'record-progress') : reconciliation_follow_ups_path(status: 'overdue')
      elsif params[:return_to] == 'queue' && @return_queue_filters
        reconciliation_follow_ups_path(@return_queue_filters)
      elsif params[:return_to] == 'overdue'
        reconciliation_follow_ups_path(status: 'overdue')
      else
        reconciliation_follow_up_path(@follow_up, close_day: @close_day&.iso8601, queue: @return_queue_filters)
      end
      notice = 'Progress saved in Rupert. Earlier notes and assignments are retained. No email or message was sent.'
      notice += ' Your selected queue now reflects this saved status, owner, due date and evidence; the request may no longer match its filters.' if params[:return_to] == 'queue' && @return_queue_filters
      notice += ' No other overdue follow-ups were found; the queue reflects your saved status and due date.' if params[:return_to] == 'next_overdue' && @next_overdue.nil?
      redirect_to destination, notice: notice
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

  def load_return_queue
    @return_queue_filters = nil
    return unless params[:queue].is_a?(ActionController::Parameters)

    values = params[:queue].permit(*ReconciliationFollowUpQueue::KEYS).to_h
    @return_queue_filters = ReconciliationFollowUpQueue.new(values).filters if values.present?
  rescue ReconciliationEvidence::Error, ActiveRecord::RecordNotFound
    @return_queue_filters = nil
  end

  def next_overdue
    ReconciliationFollowUp.active.where('due_on < ?', Date.current).where.not(id: @follow_up.id).includes(:owner).order(:due_on, :id).first
  end

  def form_options
    @owners = User.active.where(tenant_id: Current.tenant_id).order(:name, :id).select { |user| user.can?('reports.read') }
    @locations = Location.select(:id, :name, :source).order(:name).to_a
  end

  def show_options
    load_close_context
    load_return_queue
    form_options
    @next_overdue = next_overdue if @follow_up.overdue?
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
