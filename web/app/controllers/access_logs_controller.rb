# frozen_string_literal: true

# Access log: who signed in (or tried to), from which IP, when, and whether it
# worked. Written by AccessLogger on every auth attempt and sign-out.
class AccessLogsController < AuthenticatedController
  before_action :authorize_read

  def index
    scope = AccessLog.order(created_at: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(source: params[:source]) if params[:source].present?
    scope = scope.for_email(params[:q]) if params[:q].present?
    @pagy, @logs = pagy(:offset, scope, limit: 50)
  end

  private

  def authorize_read
    authorize(:module, :settings_read?)
  end
end
