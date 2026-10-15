# frozen_string_literal: true

require 'csv'

class BulkMaterialsController < BulkInventoryController
  def index
    @pagy, @materials = pagy(BulkMaterial.order(:name, :id), items: 30)
    ids = @materials.map(&:id)
    @balances = BulkLot.where(bulk_material_id: ids).group(:bulk_material_id).sum(:balance_mg)
    @lot_counts = BulkLot.where(bulk_material_id: ids).group(:bulk_material_id).count
  end

  def export
    scope = BulkMovement.joins(bulk_lot: :bulk_material).includes(bulk_lot: :bulk_material)
      .where(bulk_lots: { tenant_id: Current.tenant_id }, bulk_materials: { tenant_id: Current.tenant_id })
    csv = CSV.generate do |rows|
      rows << %w[movement_id material lot recorded_at_utc kind entered_weight entered_unit change_mg current_lot_balance_mg reference recorded_by]
      scope.find_each do |movement|
        lot = movement.bulk_lot
        rows << [movement.id, csv_text(lot.bulk_material.name), csv_text(lot.code), movement.created_at.utc.iso8601(6),
          movement.kind, movement.input_quantity, movement.input_unit, movement.delta_mg, lot.balance_mg,
          csv_text(movement.reference), csv_text(movement.created_by)]
      end
    end
    send_data(csv, filename: "rupert-bulk-ledger-#{Time.current.to_date.iso8601}.csv", type: 'text/csv; charset=utf-8')
  end

  def new
    @material = BulkMaterial.new(unit: 'g')
  end

  def create
    @material = BulkMaterial.new(params.require(:bulk_material).permit(:name, :unit))
    if @material.save
      redirect_to(bulk_material_path(@material), notice: 'Bulk material created. Record a lot receipt to add stock.')
    else
      render(:new, status: :unprocessable_entity)
    end
  rescue ActiveRecord::RecordNotUnique
    @material.errors.add(:name, 'already exists')
    render(:new, status: :unprocessable_entity)
  end

  def show
    @material = BulkMaterial.find(params[:id])
    @balance = @material.bulk_lots.sum(:balance_mg)
    @pagy, @lots = pagy(@material.bulk_lots.order(created_at: :desc, id: :desc), items: 30)
  end

  private

  def csv_text(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) || text.match?(/\A[\t\r]/) ? "'#{text}" : text
  end
end
