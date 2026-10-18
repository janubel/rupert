# frozen_string_literal: true

class StockRequestsController < AuthenticatedController
  before_action -> { authorize(:module, :inventory_read?) }
  before_action -> { authorize(:module, :inventory_write?) }, except: %i[index show]
  rescue_from StockRequestWorkflow::Error, with: :workflow_error
  rescue_from ActiveRecord::StatementInvalid do |error|
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause.class.name)

    redirect_to(stock_requests_path, alert: 'Inventory is busy. Retry from the request page; existing events are retained.')
  end

  def index
    @kind = %w[transfer backorder].include?(params[:kind]) ? params[:kind] : 'transfer'
    scope = StockRequest.where(request_kind: @kind).includes(:source_pool, :destination_pool).order(created_at: :desc, id: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    @pagy, @requests = pagy(scope, items: 30)
  end

  def show
    @stock_request = StockRequest.find(params[:id])
    @events = @stock_request.events.order(:id)
  end

  def new
    @attributes = { 'request_kind' => params[:kind].presence || 'transfer', 'inventory_level_id' => params[:inventory_level_id] }
    @token = SecureRandom.uuid
    load_choices
  end

  def create
    @attributes = params.require(:stock_request).permit(:request_kind, :inventory_level_id, :destination_location_id, :quantity, :reference, :due_on).to_h
    @token = params.require(:request_token)
    record = StockRequestWorkflow.new(actor: Current.user).create(attributes: @attributes, token: @token)
    redirect_to(record, notice: record.transfer? ? 'Transfer reserved. Record dispatch after moving stock and confirming the source adjustment.' : 'Backorder recorded. Allocate when stock becomes available.')
  rescue StockRequestWorkflow::Error => e
    @error = e.message
    load_choices
    render(:new, status: :unprocessable_entity)
  end

  def transition
    @stock_request = StockRequest.find(params[:id])
    StockRequestWorkflow.new(actor: Current.user).transition(request: @stock_request, action: params.require(:event),
      token: params.require(:request_token), quantity: params[:quantity], confirmed: params[:confirmed],
      adjusted_at: params[:adjusted_at], reference: params[:reference])
    redirect_to(@stock_request, notice: 'Inventory event recorded.')
  end

  private

  def workflow_error(error)
    redirect_to(@stock_request || stock_requests_path, alert: error.message)
  end

  def load_choices
    @query = params[:q].to_s.strip
    scope = InventoryWorkspace.levels(query: @query)
    @levels = scope.order(:source, :locationId, :id).limit(100).to_a
    selected = InventoryLevel.find_by(id: @attributes['inventory_level_id'])
    @levels.unshift(selected) if selected && @levels.none? { |level| level.id == selected.id }
    @locations = Location.where(source: %w[shopify square], active: true).order(:source, :name)
  end
end
