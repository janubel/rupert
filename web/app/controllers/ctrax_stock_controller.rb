# frozen_string_literal: true

class CtraxStockController < AuthenticatedController
  def index
    unless Current.user.can?('inventory.read')
      return redirect_to root_path, alert: 'Inventory read permission is required.'
    end

    @snapshots = CtraxStockSnapshot.includes(:location).order(captured_at: :desc).limit(20)
    response.headers['Cache-Control'] = 'no-store'
  end
end
