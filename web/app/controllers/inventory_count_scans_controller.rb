# frozen_string_literal: true

class InventoryCountScansController < AuthenticatedController
  before_action :require_inventory_write
  before_action :load_count

  rescue_from InventoryCountScan::Error, with: :scan_error
  rescue_from ActiveRecord::StatementInvalid, with: :database_error

  def show
    @items = @count.items.order(:sku)
  end

  def lookup
    render json: InventoryCountScan.new.resolve!(params[:code])
  end

  def create
    result = InventoryCountScan.new.record!(count: @count, code: params[:code],
      quantity: params[:quantity], mode: params[:mode], request_token: params[:request_token], actor: Current.user.email)
    respond_to do |format|
      format.json { render json: result }
      format.html { redirect_to scan_inventory_count_path(@count), notice: "#{result[:sku]}: counted #{result[:quantity]}." }
    end
  end

  private

  def require_inventory_write
    return if Current.user.can?('inventory.read') && Current.user.can?('inventory.write')

    respond_to do |format|
      format.json { render json: { error: "You don't have permission to scan inventory counts." }, status: :forbidden }
      format.html { redirect_to root_path, alert: "You don't have permission to scan inventory counts." }
    end
  end

  def load_count
    @count = InventoryCount.find(params[:id])
  end

  def scan_error(error)
    respond_to do |format|
      format.json { render json: { error: error.message }, status: error.status }
      format.html { redirect_to scan_inventory_count_path(@count), alert: error.message }
    end
  end

  def database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    response.set_header('Retry-After', '1')
    scan_error(InventoryCountScan::Error.new('Inventory is busy. Retry this same scan to confirm it safely.', status: :service_unavailable))
  end
end
