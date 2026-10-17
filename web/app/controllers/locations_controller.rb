# frozen_string_literal: true

# Multi-location management: physical/virtual stock locations across Shopify
# and Square. Synced locations are read-only-ish; manual ones can be added.
class LocationsController < AuthenticatedController
  before_action :set_location, only: %i[show edit update destroy]

  def index
    authorize(:module, :inventory_read?)
    @locations = Location.where(tenant_id: Current.tenant_id).order(:name)
    @total_units = InventoryLevel.where(tenant_id: Current.tenant_id).sum(:quantity)
    @per_source = Location.where(tenant_id: Current.tenant_id).group(:source).count
    @units_by_location = InventoryLevel.where(tenant_id: Current.tenant_id).group(:locationId).sum(:quantity)
  end

  def show
    authorize(:module, :inventory_read?)
    @levels = InventoryLevel.where(tenant_id: Current.tenant_id, locationId: @location.id)
                            .includes(:shopify_variant).order(:quantity).limit(100)
    @total_units = InventoryLevel.where(tenant_id: Current.tenant_id, locationId: @location.id).sum(:quantity)
  end

  def new
    authorize(:module, :inventory_write?)
    @location = Location.new(active: true, source: 'manual')
  end

  def create
    authorize(:module, :inventory_write?)
    @location = Location.new(location_params.merge(tenant_id: Current.tenant_id))
    @location.source = 'manual'
    @location.externalId = "manual-#{SecureRandom.hex(8)}"
    @location.syncedAt = Time.current
    if @location.save
      ActivityLogger.log('location_added', subject: @location)
      redirect_to(@location, notice: 'Location added.')
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    authorize(:module, :inventory_write?)
  end

  def update
    authorize(:module, :inventory_write?)
    if @location.update(location_params)
      ActivityLogger.log('location_updated', subject: @location, details: @location.previous_changes.keys.excluding('updatedAt').join(', '))
      redirect_to(@location, notice: 'Location updated.')
    else
      render(:edit, status: :unprocessable_entity)
    end
  end

  def destroy
    authorize(:module, :inventory_write?)
    return redirect_to(@location, alert: "Location has stock levels and can't be removed.") if @location.levels.any?

    @location.destroy
    ActivityLogger.log('location_removed', subject: @location)
    redirect_to(locations_path, notice: 'Location removed.')
  end

  private

  def set_location
    @location = Location.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  def location_params
    params.require(:location).permit(:name, :kind, :timezone, :active)
  end
end
