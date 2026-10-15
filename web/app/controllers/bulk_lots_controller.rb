# frozen_string_literal: true

class BulkLotsController < BulkInventoryController
  before_action :set_material

  def new
    @lot = @material.bulk_lots.new
    @receipt_attributes = { unit: @material.unit }
  end

  def create
    params.require(:bulk_lot).require(:receipt_token)
    @receipt_attributes = params.require(:bulk_lot).permit(:quantity, :unit, :reference).to_h.symbolize_keys
    @lot = BulkLedger.receive(material: @material,
      attributes: params.require(:bulk_lot).permit(:code, :note, :receipt_token).to_h.symbolize_keys,
      movement_attributes: @receipt_attributes, actor: Current.user.email)
    if @lot.persisted? && @lot.errors.empty?
      redirect_to(bulk_material_bulk_lot_path(@material, @lot), notice: 'Bulk lot receipt recorded.')
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def show
    @lot = @material.bulk_lots.find(params[:id])
    @movement = BulkMovement.new(kind: 'consume', input_unit: @material.unit)
    load_movements
  end

  private

  def set_material
    @material = BulkMaterial.find(params[:bulk_material_id])
  end

  def load_movements
    @pagy, @movements = pagy(@lot.bulk_movements.order(created_at: :desc, id: :desc), limit: 30)
  end
end
