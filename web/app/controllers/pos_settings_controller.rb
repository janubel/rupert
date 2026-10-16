# frozen_string_literal: true

class PosSettingsController < AuthenticatedController
  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can?('settings.write') && Current.user.can?('sales.write') && Current.user.can?('inventory.write')
    response.headers['Cache-Control'] = 'no-store'
    @location = Location.find_by!(id: params[:location_id], source: 'ctrax')
    @setting = PosSetting.find_or_initialize_by(location: @location)
  end
  def show; end

  def update
    fields = params.require(:pos_setting).permit(:cash_enabled, :card_enabled, :stock_writes_enabled, :environment, :gateway_id, :lock_version)
    submitted = (params[:credentials].is_a?(ActionController::Parameters) ? params[:credentials].permit(:api_login_id, :transaction_key).to_h : {}).reject { |_key, value| value.blank? }
    saved = PosSetting.transaction do
      @setting.lock! if @setting.persisted?
      @setting.assign_attributes(fields)
      @setting.credentials_json = JSON.generate(@setting.credentials.merge(submitted)) if submitted.any?
      @setting.save
    end
    if saved
      ActivityLogger.log('pos_setup_saved', subject: @setting, details: 'POS store configuration')
      redirect_to pos_setting_path(@location.id), notice: 'POS setup saved.'
    else
      render :show, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError
    redirect_to pos_setting_path(@location.id), alert: 'Setup changed. Reload before saving.'
  end

  def verify
    raise Pos::Error, 'Save the settings first.' unless @setting.persisted?
    gateway = Pos::Gateway.new(@setting)
    merchant = gateway.merchant
    count = PosSetting.where(id: @setting.id, lock_version: gateway.version).update_all(public_client_key: merchant.fetch('publicClientKey'), verified_at: Time.current, updated_at: Time.current, lock_version: gateway.version + 1)
    raise Pos::Error, 'Setup changed during the check.' if count.zero?
    redirect_to pos_setting_path(@location.id), notice: 'Gateway identity, USD and hosted-card key verified. Enable card payments when ready.'
  rescue Pos::Error => e
    redirect_to pos_setting_path(@location.id), alert: e.message
  end
end
