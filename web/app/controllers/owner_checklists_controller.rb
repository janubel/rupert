# frozen_string_literal: true

# Owner records are deliberately gated by fresh roles, never delegated settings
# permissions. No action contacts a vendor or stores account credentials.
class OwnerChecklistsController < AuthenticatedController
  OWNER_FIELDS = %i[name domain purpose owner_name owner_email owner_phone notes].freeze
  SERVICE_FIELDS = %i[name purpose login_url renewal_cadence renewal_on renewal_notes review_cadence next_review_on
    support_name support_email support_phone mfa_status vault_reference notes archived].freeze

  # Apply before inherited authentication can halt with a login redirect.
  content_security_policy(prepend: true) do |policy|
    policy.frame_ancestors :none
  end

  prepend_before_action :prevent_caching
  before_action :require_owner
  before_action :set_checklist, except: %i[index new create]
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActionController::ParameterMissing, with: :invalid_form
  rescue_from ActiveRecord::StaleObjectError, with: :stale_checklist
  rescue_from ActiveRecord::StatementInvalid, with: :busy_database

  helper_method :safe_login_url, :service_schedules, :owner_service_archived?, :owner_review_label,
    :owner_review_class, :owner_event_actor

  def index
    @pagy, @checklists = pagy(OwnerChecklist.order(updated_at: :desc, id: :desc), items: 12)
  end

  def new
    @checklist = OwnerChecklist.new
    @owner_values = {}
  end

  def create
    @owner_values = owner_params.to_h
    @checklist = OwnerChecklistWriter.create(attributes: @owner_values, actor: Current.user)
    if @checklist.persisted? && @checklist.errors.empty?
      redirect_to(owner_checklist_path(@checklist), notice: 'Private owner checklist created. No vendor was contacted.')
    else
      clear_invalid_domain
      render(:new, status: :unprocessable_entity)
    end
  end

  def show
    load_review_data
  end

  def edit
    @owner_values = @checklist.data
  end

  def update
    @owner_values = owner_params.to_h
    @checklist = OwnerChecklistWriter.update(checklist: @checklist, attributes: @owner_values,
      lock_version: submitted_version, actor: Current.user)
    if @checklist.errors.empty?
      redirect_to(owner_checklist_path(@checklist), notice: 'Owner details saved privately.')
    else
      clear_invalid_domain
      render(:edit, status: :unprocessable_entity)
    end
  end

  def service
    load_service
  end

  def save_service
    load_service
    @service_values = params.require(:owner_service).permit(*SERVICE_FIELDS).to_h
    @checklist = OwnerChecklistWriter.save_service(checklist: @checklist, service_id: @service_id,
      attributes: @service_values, lock_version: submitted_version, actor: Current.user)
    if @checklist.errors.empty?
      redirect_to(owner_checklist_path(@checklist), notice: 'Service reference saved. No account check, renewal or notification was started.')
    else
      # Never reflect an unsafe pasted login URL back into a value or link.
      @service_values['login_url'] = '' unless safe_login_url(@service_values['login_url'])
      render(:service, status: :unprocessable_entity)
    end
  end

  def feature
    load_feature
  end

  def review_feature
    load_feature
    @review_values = params.require(:owner_feature).permit(:status, :evidence, :tested_on, :attest_scope).to_h
    @checklist = OwnerChecklistWriter.review_feature(checklist: @checklist, feature_id: @feature.fetch('id'),
      attributes: @review_values, lock_version: submitted_version, actor: Current.user,
      expected_catalog_fingerprint: params[:catalog_fingerprint].presence)
    if @checklist.errors.empty?
      redirect_to(owner_checklist_path(@checklist, anchor: "feature-#{@feature.fetch('id')}"),
        notice: 'Owner review saved for the current published scope. Product readiness was not changed.')
    else
      @review_values['attest_scope'] = '0'
      render(:feature, status: :unprocessable_entity)
    end
  end

  def print
    load_review_data
    @printed_at = Time.current
    render(:print, layout: false)
  end

  private

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['X-Robots-Tag'] = 'noindex, nofollow, noarchive'
    response.headers['X-Frame-Options'] = 'DENY'
  end

  def require_owner
    actor = User.find_by(id: Current.user&.id, active: true)
    workspace = Tenant.find_by(id: Current.tenant_id, status: 'active')
    unless actor && workspace && %w[admin super_admin].include?(actor.role) &&
        (actor.super_admin? || actor.tenant_id == workspace.id)
      render(plain: 'An active owner account and workspace are required.', status: :forbidden)
      return
    end

    Current.user = actor
    Current.tenant = workspace
  end

  def set_checklist
    @checklist = OwnerChecklist.find(params[:id])
  end

  def owner_params
    params.require(:owner_checklist).permit(*OWNER_FIELDS)
  end

  def clear_invalid_domain
    @owner_values['domain'] = '' unless OwnerChecklist.public_domain?(@owner_values['domain'])
  end

  def submitted_version
    params.require(:lock_version)
  end

  def load_service
    @service_id = params[:service_id].presence
    @service_values = if @service_id
      @checklist.services.fetch(@service_id) { raise ActiveRecord::RecordNotFound }
    else
      { 'renewal_cadence' => 'unspecified', 'review_cadence' => 'unspecified', 'mfa_status' => 'unknown', 'archived' => false }
    end
  end

  def load_feature
    @feature = @checklist.features.find { |item| item.fetch('id') == params[:feature_id].to_s }
    raise ActiveRecord::RecordNotFound unless @feature

    @review_values = @checklist.feature_review(@feature)
  end

  def load_review_data
    @features = @checklist.features
    @feature_reviews = @features.to_h { |feature| [feature.fetch('id'), @checklist.feature_review(feature)] }
    @review_counts = @feature_reviews.values.group_by { |review| review['status'] }.transform_values(&:length)
    @reviewed_count = @review_counts.fetch('passed', 0) + @review_counts.fetch('not_required', 0)
    @events = @checklist.owner_checklist_events.includes(:actor).order(created_at: :desc, id: :desc).limit(20)
    @event_count = @checklist.owner_checklist_events.count
  end

  def safe_login_url(value)
    value if value.present? && OwnerChecklist.valid_login_url?(value)
  end

  def owner_service_archived?(service)
    service['archived'] == true || service['archived'] == '1'
  end

  def service_schedules(service)
    return [] if owner_service_archived?(service)

    { 'renewal_on' => 'Renewal', 'next_review_on' => 'Review' }.filter_map do |field, label|
      next if service[field].blank?

      date = Date.iso8601(service[field])
      state = date < Date.current ? :overdue : date == Date.current ? :today : :upcoming
      { label: label, date: date, state: state }
    rescue ArgumentError, TypeError
      nil
    end
  end

  def owner_review_label(status)
    { 'not_reviewed' => 'Not reviewed', 'pending' => 'Pending', 'passed' => 'Passed for stated scope',
      'blocked' => 'Blocked', 'not_required' => 'Not required', 'stale' => 'Scope changed · review again' }.fetch(status, 'Not reviewed')
  end

  def owner_review_class(status)
    { 'passed' => 'pill-fern', 'blocked' => 'pill-rose', 'stale' => 'pill-clay', 'pending' => 'pill-clay' }.fetch(status, 'pill-taupe')
  end

  def owner_event_actor(event)
    snapshot = event.data
    snapshot['actor_email'].presence || snapshot['actor_name'].presence || event.actor&.email.presence || "Former owner (#{event.actor_id})"
  end

  def not_found
    prevent_caching
    render(plain: 'Private checklist or reference not found.', status: :not_found)
  end

  def invalid_form
    prevent_caching
    render(plain: 'Reload the private form and submit its required fields.', status: :bad_request)
  end

  def stale_checklist
    redirect_to(owner_checklist_path(@checklist), alert: 'This checklist changed in another session. Reload the saved record and review your changes before saving again.')
  end

  def busy_database(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    redirect_to(owner_checklists_path, alert: 'The private checklist is busy. Reload and review the saved record before trying again.')
  end
end
