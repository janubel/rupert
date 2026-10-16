# frozen_string_literal: true

class SourceSyncsController < AuthenticatedController
  before_action :authorize_write

  def create
    case params[:source]
    when 'ctrax'
      return head(:forbidden) unless Current.user.can?('inventory.write')

      connection = PosConnection.find_by(provider: 'ctrax', vendor_approved: true)
      return redirect_to(root_path, alert: 'C-Trax read access is not configured.') unless connection&.credentials_saved?

      CtraxStockSyncJob.perform_later(connection.id, manual: true)
      redirect_to root_path, notice: 'C-Trax stock pull queued. The badge updates after the vendor read completes.'
    when 'swipesimple'
      if ENV['RUPERT_SWIPESIMPLE_INBOX'].present?
        SwipesimpleInboxJob.perform_later(tenant_id: Current.tenant_id)
        redirect_to root_path, notice: 'SwipeSimple delivery check queued. Fresh vendor files are required to update source data.'
      else
        redirect_to swipesimple_reports_path(anchor: 'import'), notice: 'Import a fresh SwipeSimple export below. Automatic vendor delivery is not configured.'
      end
    when 'authorize_net'
      connection = PosConnection.find_by(provider: 'authorize_net_reporting', vendor_approved: true)
      return redirect_to(authorize_net_portal_exports_path) unless connection&.credentials_saved?
      return head(:forbidden) unless Current.user.can?('settings.write')

      AuthorizeNetReportingJob.perform_later(tenant_id: Current.tenant_id, connection_id: connection.id,
        setup_version: connection.lock_version)
      redirect_to root_path, notice: 'Authorize.net reporting pull queued.'
    else
      head :not_found
    end
  end

  private

  def authorize_write
    authorize(:module, :sync_write?)
  end
end
