# frozen_string_literal: true

class SourceSyncsController < AuthenticatedController
  before_action :authorize_write

  def create
    case params[:source]
    when 'bank'
      return head(:forbidden) unless Current.user.can?('settings.write')

      connection = PosConnection.find_by(provider: 'iris_reporting', vendor_approved: true)
      return redirect_to(pos_connection_path('iris_reporting'), notice: 'Save authorized NAB reporting credentials to pull deposits.') unless connection&.credentials_saved?

      if connection.reporting_auth_mode == 'web'
        IrisDailyDepositsWebJob.perform_later(connection.id, manual: true, setup_version: connection.lock_version)
      else
        IrisReportingJob.perform_later(tenant_id: Current.tenant_id, connection_id: connection.id, setup_version: connection.lock_version)
      end
      redirect_to root_path, notice: 'NAB reporting pull queued.'
    when 'ctrax'
      return head(:forbidden) unless Current.user.can?('inventory.write')

      connection = PosConnection.find_by(provider: 'ctrax', vendor_approved: true)
      return redirect_to(root_path, alert: 'C-Trax read access is not configured.') unless connection&.credentials_saved?

      CtraxStockSyncJob.perform_later(connection.id, manual: true)
      redirect_to root_path, notice: 'C-Trax stock pull queued. The badge updates after the vendor read completes.'
    when 'swipesimple'
      connection = PosConnection.find_by(provider: 'swipesimple', vendor_approved: true)
      return redirect_to(pos_connection_path('swipesimple'), notice: 'Save the SwipeSimple website login to pull fresh exports.') unless connection&.credentials_saved?

      SwipesimpleWebSyncJob.perform_later(connection.id, manual: true)
      redirect_to root_path, notice: 'Fresh SwipeSimple website pull queued. The badge updates after both exports are saved.'
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
