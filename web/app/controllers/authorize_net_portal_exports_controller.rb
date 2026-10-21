# frozen_string_literal: true

class AuthorizeNetPortalExportsController < AuthenticatedController
  before_action :private_response
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: %i[create document]

  def index
    @exports = AuthorizeNetPortalExport.order(exported_at: :desc).limit(20)
    @rows = AuthorizeNetPortalObservation.recent(200)
    @observation_count = AuthorizeNetPortalObservation.transaction_count
    @settled_totals = AuthorizeNetPortalObservation.latest_totals(status: 'Settled Successfully', transaction_type: 'Authorization w/ Auto Capture')
  end

  def create
    file = params[:file]
    raise AuthorizeNetPortalImporter::Error, 'Attach a native expanded CSV export no larger than 8 MiB.' unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size <= AuthorizeNetPortalImporter::MAX_BYTES

    receipt = AuthorizeNetPortalImporter.import!(text: file.read(AuthorizeNetPortalImporter::MAX_BYTES + 1),
      gateway_id: params[:gateway_id], kind: params[:kind], exported_at: params[:exported_at])
    redirect_to authorize_net_portal_exports_path, notice: "Portal export saved: #{receipt.records.size} transaction observations."
  rescue AuthorizeNetPortalImporter::Error => e
    redirect_to authorize_net_portal_exports_path, alert: e.message
  rescue ArgumentError
    redirect_to authorize_net_portal_exports_path, alert: 'Portal import could not be validated. Check the native CSV, Gateway ID, kind and export time.'
  end

  def document
    receipt = AuthorizeNetPortalExport.find(params[:id])
    send_data receipt.original_csv, type: 'text/csv', disposition: 'attachment', filename: "authorize-net-portal-#{receipt.id}.csv"
  end

  private

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def authorize_read
    authorize(:module, :reports_read?)
  end

  def authorize_write
    authorize(:module, :sync_write?)
  end
end
