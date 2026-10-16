# frozen_string_literal: true

# One entry point for credential setup, source health and explicit repairs.
class ConnectionsController < AuthenticatedController
  before_action :authorize_read, only: %i[index edit]
  before_action :authorize_write, only: :update
  before_action :require_active_workspace
  before_action :prevent_caching
  before_action :load_managed_service, only: %i[edit update]

  def index
    @services = ConnectionControlCenter.services
    @sync_sources = ConnectionControlCenter.sources
  rescue ActiveRecord::Encryption::Errors::Decryption
    @sync_sources = []
    @status_notice = 'Source health cannot be read with the current encryption keys. Ask the platform operator to restore keys; do not replace saved credentials.'
  end

  def edit; end

  def update
    input = params.require(:connection_credentials).permit(:edit_token, clear_keys: [], values: {}).to_h.symbolize_keys
    count = ConnectionCredentials.save!(@service.key, input, actor: Current.user)
    ActivityLogger.log('connection_credentials_saved', details: @service.key) if count.positive?
    redirect_to edit_connection_path(@service.key), notice: count.positive? ? 'Credentials saved. No access check, sync or schedule change was started.' : 'No credential changes submitted.'
  rescue ConnectionCredentials::Error => error
    redirect_to edit_connection_path(@service.key), alert: error.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to edit_connection_path(@service.key), alert: 'Setup could not be saved safely. Reload and review the current connection.'
  end

  private

  def authorize_read
    authorize(:module, :settings_read?)
  end

  def authorize_write
    authorize(:module, :settings_write?)
  end

  def require_active_workspace
    return if Current.user.active? && Current.tenant&.status == 'active'

    render plain: 'An active workspace and account are required.', status: :forbidden
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end

  def load_managed_service
    raise ActiveRecord::RecordNotFound unless ConnectionCredentials::FIELDS.key?(params[:service])

    @service = ConnectionsGuide::SERVICES.find { |service| service.key == params[:service] }
    @fields = ConnectionCredentials.display_fields(@service.key)
    @edit_token = ConnectionCredentials.token(@service.key, actor: Current.user)
  end
end
