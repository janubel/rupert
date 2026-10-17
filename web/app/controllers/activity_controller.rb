# frozen_string_literal: true

require 'csv'

# Audit trail: a chronological, filterable log of business and operator actions.
class ActivityController < AuthenticatedController
  # Prefix groups so a reviewer can jump straight to money or operator changes.
  GROUPS = {
    'money' => ['Money & reconciliation',
      %w[reconciliation_ daily_ financial_close cash_forecast money_reconciliation expense_ payment_ po_ pay_run refund_ authorize_net_ ctrax_day]],
    'operator' => ['Settings, access & credentials',
      %w[settings_ database_ drive_ oauth_ google_signin api_token role_permissions employee_ business_settings fulfillment_workflow location_ connection_ pos_connection pos_setup legacy_broad]]
  }.freeze

  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def index
    authorize(:module, :settings_read?)
    scope = filtered(ActivityLog.where(tenant_id: Current.tenant_id).order(created_at: :desc, id: :desc))
    respond_to do |format|
      format.html { @pagy, @activities = pagy(scope, items: 50) }
      format.csv { send_data(csv_for(scope.limit(10_000)), type: 'text/csv', filename: "activity-#{Date.current.iso8601}.csv") }
    end
  end

  private

  def filtered(scope)
    if (group = GROUPS[params[:group]])
      scope = scope.where(group.last.map { 'action LIKE ?' }.join(' OR '), *group.last.map { |prefix| "#{prefix}%" })
    end
    if params[:q].present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip)}%"
      scope = scope.where('action LIKE :q OR actor_name LIKE :q OR subject_label LIKE :q OR details LIKE :q', q: like)
    end
    from = parse_date(params[:from])
    to = parse_date(params[:to])
    scope = scope.where(created_at: from.beginning_of_day..) if from
    scope = scope.where(created_at: ..to.end_of_day) if to
    scope
  end

  def parse_date(value)
    Date.iso8601(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def csv_for(scope)
    CSV.generate do |csv|
      csv << ['When', 'Who', 'Action', 'Subject type', 'Subject', 'Details']
      scope.each do |a|
        csv << [a.created_at.in_time_zone.iso8601, a.actor_name, a.action, a.subject_type, a.subject_label, a.details].map { |v| safe(v) }
      end
    end
  end

  def safe(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) ? "'#{text}" : text
  end
end
