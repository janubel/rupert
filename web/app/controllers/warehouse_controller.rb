# frozen_string_literal: true

# Admin overview of warehouse-sale vendor links and the global bulk tier
# schedule applied to every vendor by default.
class WarehouseController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: :update_tiers

  def index
    @global_tiers = WarehouseTier.where(shareId: nil).order(:minQty)
    @shares = WarehouseShare.order(:name)
    if Current.user.can?('sales.read') && Current.user.can?('inventory.read')
      @hold_count = WarehouseStockHold.held.count
      @stock_holds = WarehouseStockHold.held.includes(:order, :warehouse_payment_attempt, warehouse_cart: [:share, :items])
        .order(:created_at, :id).limit(100)
    end
  end

  def update_tiers
    params.to_unsafe_hash.fetch('tiers', {}).each_value do |attrs|
      if attrs[:_destroy] == '1'
        WarehouseTier.where(shareId: nil).find_by(id: attrs[:id])&.destroy
      elsif attrs[:minQty].present?
        tier = WarehouseTier.where(shareId: nil).find_by(id: attrs[:id]) || WarehouseTier.new(shareId: nil)
        tier.minQty = attrs[:minQty]
        tier.discountPercent = attrs[:discountPercent]
        tier.save!
      end
    end
    redirect_to(warehouse_path, notice: 'Global tier schedule updated')
  rescue ActiveRecord::RecordInvalid => e
    redirect_to(warehouse_path, alert: e.record.errors.full_messages.join(', '))
  end

  private

  def authorize_read
    authorize(:module, :settings_read?)
  end

  def authorize_write
    authorize(:module, :settings_write?)
  end
end
