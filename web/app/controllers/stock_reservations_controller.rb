# frozen_string_literal: true

class StockReservationsController < AuthenticatedController
  rescue_from ActiveRecord::StatementInvalid, with: :handle_database_error

  before_action :authorize_read
  before_action :authorize_write, except: :index

  def index
    scope = StockReservation.includes(:stock_reservation_pool).recent
    @pagy, @reservations = pagy(scope, items: 30)
  end

  def new
    @reservation = StockReservation.new
    load_levels
  end

  def create
    params.require(:stock_reservation).require(:request_token)
    @reservation = StockReservationService.reserve(
      inventory_level_id: params.require(:stock_reservation).require(:inventory_level_id),
      attributes: reservation_params.to_h.symbolize_keys, actor: Current.user.email
    )
    if @reservation.persisted?
      redirect_to(stock_reservations_path, notice: 'Local reservation created. Platform stock was not changed.')
    else
      load_levels
      render(:new, status: :unprocessable_entity)
    end
  end

  def release
    reservation = StockReservation.find(params[:id])
    StockReservationService.release(reservation, actor: Current.user.email)
    redirect_to(stock_reservations_path, notice: 'Local reservation released.')
  end

  private

  def handle_database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause.class.name)

    redirect_to(stock_reservations_path, alert: 'Inventory is busy. Please retry; the reservation change was not saved.')
  end

  def authorize_read
    authorize(:module, :inventory_read?)
  end

  def authorize_write
    authorize(:module, :inventory_write?)
  end

  def reservation_params
    params.require(:stock_reservation).permit(:quantity, :reference, :expires_at, :request_token)
  end

  def load_levels
    @query = params[:q].to_s.strip
    @selected_level = InventoryLevel.find_by(id: params.dig(:stock_reservation, :inventory_level_id) || params[:inventory_level_id])
    scope = InventoryLevel.where(source: %w[shopify square]).includes(:location, :shopify_variant, :square_variation)
    if @query.present?
      shopify_ids = ShopifyVariant.search(@query).select(:id)
      square_ids = SquareVariation.search(@query).select(:id)
      scope = scope.where(shopifyVariantId: shopify_ids).or(scope.where(squareVariationId: square_ids))
    end
    @levels = scope.order(:source, :locationId, :id).limit(100).to_a
    @levels.unshift(@selected_level) if @selected_level && @levels.none? { |level| level.id == @selected_level.id }
    @held_by_pool = StockReservation.active_at.joins(:stock_reservation_pool)
      .group('stock_reservation_pools.source', 'stock_reservation_pools.location_id', 'stock_reservation_pools.source_item_id')
      .sum(:quantity)
  end
end
