# frozen_string_literal: true

class PosConnectionsController < AuthenticatedController
  before_action :authorize_access
  before_action :prevent_caching
  before_action :load_connection, except: :index
  rescue_from ActiveRecord::StatementInvalid, with: :handle_busy_database

  def index
    @providers = PosProviderCatalog.all
    @connections = PosConnection.all.index_by(&:provider)
  end

  def show
    return load_iris_reports if @provider[:key] == 'iris_reporting'
    return unless @provider[:key] == 'authorize_net_reporting'
    scope = { environment: @connection.environment, gateway_id: @connection.account_reference }
    @report_date = params[:report_date].present? ? Date.iso8601(params[:report_date]) : Time.current.utc.to_date
    start = Time.iso8601("#{@report_date}T00:00:00Z")
    day = start...(start + 1.day)
    transactions = AuthorizeNetTransaction.where(**scope)
    relevant = transactions.where('submitted_at >= ? AND submitted_at < ? OR settled_at >= ? AND settled_at < ?', day.begin, day.end, day.begin, day.end)
    @report_transactions = relevant.order(submitted_at: :desc).limit(100)
    @report_transaction_count = relevant.count
    @report_batches = AuthorizeNetBatch.where(**scope, settled_at: day).order(settled_at: :desc).limit(30)
    # Group currency separately; never add amounts across currencies.
    @report_totals = transactions.where(settled_at: day, payment_status: %w[settledSuccessfully refundSettledSuccessfully])
      .where.not(currency: nil).group(:currency, :payment_status).sum(:settled_amount)
    @report_status_counts = transactions.where(submitted_at: day).group(:payment_status).count
  rescue ArgumentError
    redirect_to pos_connection_path(@provider[:key]), alert: 'Choose a valid UTC reporting date.'
  end

  def import_reporting
    return import_iris_reporting if @provider[:key] == 'iris_reporting'
    raise ActiveRecord::RecordNotFound unless @provider[:key] == 'authorize_net_reporting'
    unless @connection.persisted? && @connection.vendor_approved && @connection.credentials_saved?
      return redirect_to pos_connection_path(@provider[:key]), alert: 'Save approved reporting credentials before importing.'
    end
    from = params[:from].present? ? Time.iso8601("#{Date.iso8601(params[:from])}T00:00:00Z") : 7.days.ago
    to = params[:to].present? ? Time.iso8601("#{Date.iso8601(params[:to])}T23:59:59Z") : Time.current
    raise ArgumentError unless from < to && to - from <= 31.days
    AuthorizeNetReportingJob.perform_later(tenant_id: Current.tenant_id, connection_id: @connection.id,
      setup_version: @connection.lock_version, from: from.utc.iso8601, to: to.utc.iso8601)
    redirect_to pos_connection_path(@provider[:key]), notice: 'Reporting import queued. Refresh this page to see the result.'
  rescue ArgumentError
    redirect_to pos_connection_path(@provider[:key]), alert: 'Enter valid UTC dates for a reporting window of at most 31 days.'
  end

  def import_iris_csv
    raise ActiveRecord::RecordNotFound unless @provider[:key] == 'iris_reporting'
    file = params[:report_file]
    raise IrisReporting::Client::Error, :response unless file.respond_to?(:read)

    text = file.read(IrisReporting::CsvImport::MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
    if params[:report_kind] == 'daily_deposits_csv'
      report = IrisReporting::DailyDepositsCsvImport.call(text: text, merchant: params[:merchant_number].to_s, period: params[:report_period],
        origin: @connection.credential_values['api_url'].presence || 'https://nabankco.iriscrm.com')
      ActivityLogger.log('iris_daily_deposits_imported', subject: report, details: 'Native Daily Deposits CSV snapshot')
      return redirect_to pos_connection_path('iris_reporting'), notice: 'Imported native Daily Deposits report. No sales or inventory changed.'
    end
    count = IrisReporting::CsvImport.call(text: text, merchant: params[:merchant_number].to_s,
      kind: params[:report_kind].to_s, year: params[:report_year],
      origin: @connection.credential_values['api_url'].presence || 'https://nabankco.iriscrm.com')
    ActivityLogger.log('iris_summary_imported', subject: @connection.persisted? ? @connection : nil, details: "#{count} monthly summaries")
    redirect_to pos_connection_path('iris_reporting'), notice: "Imported #{count} monthly IRIS summaries. No sales or inventory changed."
  rescue IrisReporting::Client::Error => e
    redirect_to pos_connection_path('iris_reporting'), alert: "#{e.message} For Daily Deposits, use the original CSV and matching report month. For Health Center summaries, use the documented template or English matrix."
  end

  def update
    if @provider[:key] == 'ctrax' && ActiveModel::Type::Boolean.new.cast(params.dig(:pos_connection,
      :hourly_sync_enabled)) && !Current.user.can?('inventory.write')
      return render plain: 'Inventory write permission is required for hourly sync.', status: :forbidden
    end

    attributes = setup_params.except(:credential_secret).to_h
    @connection.apply_setup(attributes, setup_params[:credential_secret] || {})
    @connection.updated_by = Current.user
    if @connection.save
      ActivityLogger.log('pos_connection_saved', subject: @connection, details: @provider[:key])
      redirect_to pos_connection_path(@provider[:key]),
        notice: 'Setup saved. No sync, account check or payment was started.'
    else
      render :show, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique
    redirect_to pos_connection_path(@provider[:key]),
      alert: 'This setup changed in another session. Reload and review it before saving.'
  end

  def check_access
    unless (@connection.check_kind || %w[authorize_net_reporting iris_reporting swipesimple].include?(@provider[:key])) && @connection.persisted? && @connection.vendor_approved && @connection.credentials_saved?
      return redirect_to pos_connection_path(@provider[:key]), alert: 'Save approved API credentials before checking API access.'
    end

    setup_version = @connection.lock_version
    arguments = { credentials: @connection.credential_values }
    arguments[:environment] = @connection.environment if %w[authorize_net nmi].include?(@connection.check_kind)
    result = if @provider[:key] == 'swipesimple'
      SwipesimpleWeb::Check.call(connection: @connection)
    elsif @provider[:key] == 'iris_reporting'
      IrisReporting::Check.call(connection: @connection)
    elsif @provider[:key] == 'authorize_net_reporting'
      AuthorizeNetReporting::Check.call(connection: @connection)
    else
      checker.call(**arguments)
    end
    setup_version = @connection.lock_version if @provider[:key] == 'authorize_net_reporting'
    # A single conditional write avoids SQLite deferred read-to-write upgrades.
    # No database transaction is held while the provider request is in flight.
    updated = PosConnection.where(id: @connection.id, lock_version: setup_version).update_all(
      last_check_status: result.fetch(:status), last_check_message: result.fetch(:message),
      last_checked_at: Time.current, updated_at: Time.current, lock_version: setup_version + 1
    )
    if updated.zero?
      return redirect_to pos_connection_path(@provider[:key]),
        alert: 'Setup changed during the check. Check the current credentials again.'
    end

    @connection.reload
    ActivityLogger.log('pos_connection_checked', subject: @connection, details: "#{@provider[:key]}:#{result[:status]}")
    redirect_to pos_connection_path(@provider[:key]),
      (result[:status] == 'verified' ? { notice: result.fetch(:message) } : { alert: result.fetch(:message) })
  end

  def disconnect
    if @connection.persisted?
      updated = PosConnection.where(id: @connection.id, lock_version: @connection.lock_version).update_all(
        credentials_json: '{}', hourly_sync_enabled: false, reporting_enabled: false, last_report_status: nil, last_report_message: nil, last_reported_at: nil, last_check_status: nil, last_check_message: nil, last_checked_at: nil,
        updated_by_id: Current.user.id, updated_at: Time.current, lock_version: @connection.lock_version + 1
      )
      if updated.zero?
        return redirect_to pos_connection_path(@provider[:key]),
          alert: 'Setup changed. Review it and remove the current credentials again.'
      end

      @connection.reload
    end
    if @connection.persisted?
      ActivityLogger.log('pos_connection_credentials_removed', subject: @connection,
        details: @provider[:key])
    end
    redirect_to pos_connection_path(@provider[:key]),
      notice: 'Saved API credentials removed from Rupert. The vendor account and its permissions were not changed.'
  end

  def sync_stock
    raise ActiveRecord::RecordNotFound unless @provider[:key] == 'ctrax'
    unless Current.user.can?('inventory.write')
      return render plain: 'Inventory write permission is required.',
        status: :forbidden
    end

    result = Ctrax::StockSync.call(connection: @connection)
    ActivityLogger.log('ctrax_stock_synced', subject: @connection,
      details: "#{result[:stores]} stores, #{result[:variants]} variants")
    redirect_to ctrax_stock_index_path,
      notice: "C-Trax stock synced: #{result[:stores]} stores, #{result[:variants]} variants."
  rescue Ctrax::Client::Error => e
    redirect_to pos_connection_path('ctrax'), alert: e.message
  end

  private

  def load_iris_reports
    @iris_reports = IrisReport.order(observed_at: :desc).limit(30)
  end

  def import_iris_reporting
    unless @connection.persisted? && @connection.vendor_approved && @connection.credentials_saved?
      return redirect_to pos_connection_path('iris_reporting'), alert: 'Save authorized NAB reporting credentials before importing.'
    end
    if @connection.reporting_auth_mode == 'web'
      IrisDailyDepositsWebJob.perform_later(@connection.id, manual: true, setup_version: @connection.lock_version)
      return redirect_to pos_connection_path('iris_reporting'), notice: 'Fresh NAB Daily Deposits pull queued for the current and previous months.'
    end
    from = params[:from].present? ? Date.iso8601(params[:from]) : Date.current - 30
    to = params[:to].present? ? Date.iso8601(params[:to]) : Date.current
    raise ArgumentError unless from <= to && (to - from).to_i <= 89

    IrisReportingJob.perform_later(tenant_id: Current.tenant_id, connection_id: @connection.id,
      setup_version: @connection.lock_version, from: from.iso8601, to: to.iso8601)
    redirect_to pos_connection_path('iris_reporting'), notice: 'IRIS reporting import queued. Refresh to see the result.'
  rescue ArgumentError
    redirect_to pos_connection_path('iris_reporting'), alert: 'Choose valid source reporting dates covering at most 90 dates.'
  end

  def authorize_access
    authorize(:module, action_name.in?(%w[index show]) ? :settings_read? : :settings_write?)
    return if Current.user.active? && Current.tenant&.status == 'active'

    render plain: 'An active workspace and account are required.', status: :forbidden
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end

  def load_connection
    @provider = PosProviderCatalog.find(params[:provider])
    raise ActiveRecord::RecordNotFound unless @provider

    @connection = PosConnection.find_by(provider: @provider[:key]) || PosConnection.new(provider: @provider[:key], environment: %w[iris_reporting swipesimple].include?(@provider[:key]) ? 'production' : 'sandbox')
  end

  def setup_params
    requested = params.require(:pos_connection)
    gateway = @provider[:key] == 'valmar' ? requested.fetch(:gateway, @connection.gateway) : @connection.gateway
    keys = if @provider[:key] == 'authorize_net_reporting'
      requested.fetch(:reporting_auth_mode, @connection.reporting_auth_mode) == 'oauth' ? %w[client_id client_secret refresh_token] : %w[api_login_id transaction_key]
    elsif @provider[:key] == 'iris_reporting' && requested.fetch(:reporting_auth_mode, @connection.reporting_auth_mode) == 'web'
      %w[web_username web_password]
    else
      PosProviderCatalog.credential_keys(@provider[:key], gateway: gateway)
    end
    requested.permit(:environment, :account_reference, :access_requested, :vendor_approved, :lock_version,
      *(@provider[:key] == 'ctrax' ? [:hourly_sync_enabled] : []),
      *(@provider[:key] == 'valmar' ? [:gateway] : []),
      *(@provider[:key] == 'authorize_net_reporting' ? [:reporting_auth_mode, :reporting_enabled] : []),
      *(@provider[:key] == 'iris_reporting' ? [:reporting_auth_mode] : []),
      *(%w[iris_reporting swipesimple].include?(@provider[:key]) ? [:reporting_enabled] : []), credential_secret: keys)
  end

  def handle_busy_database(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    redirect_to pos_connection_path(params[:provider]), alert: 'Connection setup is busy. Reload and try again.'
  end

  def checker
    case @connection.check_kind
    when 'ctrax' then PaymentProviders::CtraxCheck
    when 'korona' then PaymentProviders::KoronaCheck
    when 'cova' then PaymentProviders::CovaCheck
    when 'authorize_net' then PaymentProviders::AuthorizeNetCheck
    when 'nmi' then PaymentProviders::NmiCheck
    else raise ActiveRecord::RecordNotFound
    end
  end
end
