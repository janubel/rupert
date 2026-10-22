# frozen_string_literal: true

class BulkMovementsController < BulkInventoryController
  def create
    @material = BulkMaterial.find(params[:bulk_material_id])
    @lot = @material.bulk_lots.find(params[:bulk_lot_id])
    params.require(:bulk_movement).require(:request_token)
    @movement = BulkLedger.record(lot: @lot,
      attributes: params.require(:bulk_movement).permit(:kind, :quantity, :unit, :reference, :request_token).to_h.symbolize_keys,
      actor: Current.user.email)
    if @movement.persisted? && @movement.errors.empty?
      redirect_to(bulk_material_bulk_lot_path(@material, @lot), notice: 'Bulk material movement recorded.')
    else
      @pagy, @movements = pagy(:offset, @lot.bulk_movements.order(created_at: :desc, id: :desc), limit: 30)
      render('bulk_lots/show', status: :unprocessable_entity)
    end
  end
end
