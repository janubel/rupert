# frozen_string_literal: true

require 'csv'

class BulkConsumptionsController < BulkInventoryController
  CONTRACT = 'bulk-sale-consumption-v1'
  before_action :authorize_inventory_write, only: :preview
  before_action :prevent_caching

  def index
    set_dates

    scope = Core::OrderLine.joins(:order).where(orders: { tenant_id: Current.tenant_id, source: 'shopify',
      occurred_at: @from.in_time_zone.beginning_of_day...(@to + 1).in_time_zone.beginning_of_day })
    @pagy, @lines = pagy(:offset, scope.includes(:order).order('orders.occurred_at DESC, order_lines.id DESC'), limit: 25)
    @receipts = BulkConsumption.where(source_order_id: @lines.map { |line| line.order.source_order_id },
      source_line_id: @lines.map(&:source_line_id).compact).index_by { |receipt| [receipt.source_order_id, receipt.source_line_id] }
    @mapped_variants = BulkRecipe.where(source_variant_id: @lines.map(&:source_variant_id).compact).distinct.pluck(:source_variant_id)
    @recent = BulkConsumption.includes(:bulk_recipe, bulk_lot: :bulk_material).order(created_at: :desc, id: :desc).limit(25)
    @receipt_audit = BulkSaleConsumption.audit_states((@receipts.values + @recent.to_a).uniq(&:id))
  rescue ArgumentError
    redirect_to(bulk_consumptions_path, alert: 'Choose a calendar range of 1–31 days.')
  end

  def export
    set_dates
    receipts = BulkConsumption.where(created_at: @from.in_time_zone.beginning_of_day...(@to + 1).in_time_zone.beginning_of_day)
      .includes(:bulk_recipe, bulk_lot: :bulk_material)
    csv = CSV.generate do |rows|
      rows << %w[receipt_id source source_order_id source_line_id source_variant_id order_number quantity recipe_id recipe_version material lot mg_per_unit consumed_mg movement_id recorded_at_utc recorded_by]
      receipts.find_each do |receipt|
        rows << [receipt.id, *[receipt.source, receipt.source_order_id, receipt.source_line_id, receipt.source_variant_id, receipt.order_number].map { |value| csv_text(value) },
          receipt.quantity, receipt.bulk_recipe_id, receipt.bulk_recipe.version,
          csv_text(receipt.bulk_lot.bulk_material.name), csv_text(receipt.bulk_lot.code), receipt.mg_per_unit,
          receipt.consumed_mg, receipt.bulk_movement_id, receipt.created_at.utc.iso8601(6), csv_text(receipt.created_by)]
      end
    end
    send_data(csv, filename: "rupert-sale-material-use-#{@from}-#{@to}.csv", type: 'text/csv; charset=utf-8')
  rescue ArgumentError
    redirect_to(bulk_consumptions_path, alert: 'Choose a calendar range of 1–31 days.')
  end

  def new
    load_context(params)
  end

  def preview
    load_context(params.require(:bulk_consumption))
    @plan = BulkSaleConsumption.preview(order_id: @order.id, source_line_id: @line.source_line_id, lot_id: @lot_id)
    @preview_token = verifier.generate(
      { 'tenant_id' => Current.tenant_id, 'user_id' => Current.user.id.to_s, 'order_id' => @order.id,
        'source_line_id' => @line.source_line_id, 'lot_id' => @plan.lot.id, 'recipe_id' => @plan.recipe.id,
        'fingerprint' => @plan.fingerprint, 'request_token' => SecureRandom.uuid, 'contract' => CONTRACT },
      expires_in: 15.minutes, purpose: CONTRACT
    )
    render :new
  rescue BulkSaleConsumption::Error => e
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  def create
    submitted = params.require(:bulk_consumption)
    proof = verifier.verified(submitted[:preview_token].to_s, purpose: CONTRACT)
    unless proof.is_a?(Hash) && proof['tenant_id'] == Current.tenant_id && proof['user_id'] == Current.user.id.to_s &&
      proof['contract'] == CONTRACT && submitted[:confirmed] == '1'
      raise BulkSaleConsumption::Error, 'Review and confirm this exact deduction before recording it. Reviews expire after 15 minutes.'
    end
    receipt = BulkSaleConsumption.apply!(order_id: proof.fetch('order_id'), source_line_id: proof.fetch('source_line_id'),
      lot_id: proof.fetch('lot_id'), recipe_id: proof.fetch('recipe_id'), expected_fingerprint: proof.fetch('fingerprint'),
      request_token: proof.fetch('request_token'), actor: Current.user.email)
    redirect_to(bulk_consumptions_path, notice: "Material use recorded as audit receipt ##{receipt.id}. Repeating this sale line cannot deduct it twice.")
  rescue BulkSaleConsumption::Error => e
    redirect_to(bulk_consumptions_path, alert: e.message)
  end

  private

  def set_dates
    @from = Date.iso8601((params[:from].presence || 14.days.ago.to_date.iso8601).to_s)
    @to = Date.iso8601((params[:to].presence || Date.current.iso8601).to_s)
    raise ArgumentError unless @to >= @from && (@to - @from).to_i < 31
  end

  def csv_text(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) || text.match?(/\A[\t\r]/) ? "'#{text}" : text
  end

  def load_context(values)
    unless values[:order_id].to_s.match?(/\A[1-9][0-9]*\z/) && values[:source_line_id].is_a?(String) &&
      values[:source_line_id].bytesize.between?(1, 255)
      raise ActiveRecord::RecordNotFound
    end
    @order = Core::Order.find(values[:order_id])
    @line = @order.order_lines.find_by!(source_line_id: values[:source_line_id])
    @recipe = BulkRecipe.where(source: 'shopify', source_variant_id: @line.source_variant_id)
      .where('effective_from <= ?', @order.occurred_at).order(effective_from: :desc, version: :desc).first
    @lots = @recipe ? BulkLot.where(bulk_material_id: @recipe.bulk_material_id).order(:code, :id).limit(201).to_a : []
    @lots_limited = @lots.length > 200
    @lots = @lots.first(200)
    @lot_id = values[:lot_id]
  end

  def verifier
    Rails.application.message_verifier('bulk-sale-consumption')
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
  end
end
