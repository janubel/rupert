# frozen_string_literal: true

class InventoryExceptionsController < AuthenticatedController
  before_action :authorize_read

  def index
    response.headers['Cache-Control'] = 'no-store'
    @queue = InventoryExceptions.new(source: params[:source], location_id: params[:location_id],
      stale_hours: params[:stale_hours].presence || 1, page: params[:page].presence || 1, section: params[:section])
    locations = Location.order(:source, :name, :id)
    locations = locations.where(source: @queue.source) if @queue.source
    @locations = locations.limit(201).to_a
    @locations_limited = @locations.length > 200
    @locations = @locations.first(200)
  rescue ArgumentError
    redirect_to(inventory_exceptions_path, alert: 'Choose a valid source, section, page and stale threshold (1–168 hours).')
  end

  private

  def authorize_read
    authorize(:module, :inventory_read?)
  end
end
