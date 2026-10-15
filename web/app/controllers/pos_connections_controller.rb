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

  def show; end

  def update
    attributes = setup_params.except(:credential_secret).to_h
    @connection.apply_setup(attributes, setup_params[:credential_secret] || {})
    @connection.updated_by = Current.user
    if @connection.save
      ActivityLogger.log('pos_connection_saved', subject: @connection, details: @provider[:key])
      redirect_to pos_connection_path(@provider[:key]), notice: 'Setup saved. No sync, account check or payment was started.'
    else
      render :show, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique
    redirect_to pos_connection_path(@provider[:key]), alert: 'This setup changed in another session. Reload and review it before saving.'
  end

  def check_access
    unless @connection.check_kind && @connection.persisted? && @connection.vendor_approved && @connection.credentials_saved?
      return redirect_to pos_connection_path(@provider[:key]), alert: 'Save approved API credentials before checking API access.'
    end
    setup_version = @connection.lock_version
    arguments = { credentials: @connection.credential_values }
    arguments[:environment] = @connection.environment if %w[authorize_net nmi].include?(@connection.check_kind)
    result = checker.call(**arguments)
    # A single conditional write avoids SQLite deferred read-to-write upgrades.
    # No database transaction is held while the provider request is in flight.
    updated = PosConnection.where(id: @connection.id, lock_version: setup_version).update_all(
      last_check_status: result.fetch(:status), last_check_message: result.fetch(:message),
      last_checked_at: Time.current, updated_at: Time.current, lock_version: setup_version + 1
    )
    if updated.zero?
      return redirect_to pos_connection_path(@provider[:key]), alert: 'Setup changed during the check. Check the current credentials again.'
    end
    @connection.reload
    ActivityLogger.log('pos_connection_checked', subject: @connection, details: "#{@provider[:key]}:#{result[:status]}")
    redirect_to pos_connection_path(@provider[:key]), (result[:status] == 'verified' ? { notice: result.fetch(:message) } : { alert: result.fetch(:message) })
  end

  def disconnect
    if @connection.persisted?
      updated = PosConnection.where(id: @connection.id, lock_version: @connection.lock_version).update_all(
        credentials_json: '{}', last_check_status: nil, last_check_message: nil, last_checked_at: nil,
        updated_by_id: Current.user.id, updated_at: Time.current, lock_version: @connection.lock_version + 1
      )
      return redirect_to pos_connection_path(@provider[:key]), alert: 'Setup changed. Review it and remove the current credentials again.' if updated.zero?

      @connection.reload
    end
    ActivityLogger.log('pos_connection_credentials_removed', subject: @connection, details: @provider[:key]) if @connection.persisted?
    redirect_to pos_connection_path(@provider[:key]), notice: 'Saved API credentials removed from Rupert. The vendor account and its permissions were not changed.'
  end

  private

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

    @connection = PosConnection.find_by(provider: @provider[:key]) || PosConnection.new(provider: @provider[:key])
  end

  def setup_params
    requested = params.require(:pos_connection)
    gateway = @provider[:key] == 'valmar' ? requested.fetch(:gateway, @connection.gateway) : @connection.gateway
    keys = PosProviderCatalog.credential_keys(@provider[:key], gateway: gateway)
    requested.permit(:environment, :account_reference, :access_requested, :vendor_approved, :lock_version,
      *(@provider[:key] == 'valmar' ? [:gateway] : []), credential_secret: keys)
  end

  def handle_busy_database(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    redirect_to pos_connection_path(params[:provider]), alert: 'Connection setup is busy. Reload and try again.'
  end

  def checker
    case @connection.check_kind
    when 'korona' then PaymentProviders::KoronaCheck
    when 'cova' then PaymentProviders::CovaCheck
    when 'authorize_net' then PaymentProviders::AuthorizeNetCheck
    when 'nmi' then PaymentProviders::NmiCheck
    else raise ActiveRecord::RecordNotFound
    end
  end
end
