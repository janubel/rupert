# frozen_string_literal: true

module Purchasing
  # Purchase orders: build in draft, place the order, record what arrives, and
  # track what's owed to the vendor.
  class PurchaseOrdersController < AuthenticatedController
    before_action -> { authorize(:module, :purchasing_read?) }
    before_action :set_purchase_order,
      only: %i[show edit update destroy place_order receive cancel add_line remove_line]

    # Serialize all order mutations with receiving, including cancellation and
    # draft line edits. Reload after the lock so stale tabs cannot edit placed POs.
    around_action :serialize_change, only: %i[update destroy place_order receive cancel add_line remove_line]

    def index
      authorize(:module, :purchasing_read?)
      @status = params[:status].presence || 'all'
      @purchase_orders = Purchasing::PurchaseOrder.by_status(@status).recent(200).includes(:vendor)
    end

    def show
      authorize(:module, :purchasing_read?)
      @lines = @purchase_order.lines.order(:id)
    end

    def new
      authorize(:module, :purchasing_write?)
      @purchase_order = Purchasing::PurchaseOrder.new(vendor_id: params[:vendor_id])
      @purchase_order.order_number = next_order_number
      @vendors = Purchasing::Vendor.ordered
    end

    def create
      authorize(:module, :purchasing_write?)
      @purchase_order = Purchasing::PurchaseOrder.new(purchase_order_params)
      if @purchase_order.save
        redirect_to(@purchase_order, notice: 'Purchase order created. Add lines to it.')
      else
        @vendors = Purchasing::Vendor.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :purchasing_write?)
      @vendors = Purchasing::Vendor.ordered
    end

    def update
      authorize(:module, :purchasing_write?)
      return redirect_to(@purchase_order, alert: 'Only draft orders can be edited.') unless @purchase_order.draft?

      if @purchase_order.update(purchase_order_params)
        redirect_to(@purchase_order, notice: 'Purchase order updated.')
      else
        @vendors = Purchasing::Vendor.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :purchasing_write?)
      return redirect_to(@purchase_order, alert: 'Only draft orders can be deleted.') unless @purchase_order.draft?

      @purchase_order.destroy
      redirect_to(purchase_orders_path, notice: 'Purchase order deleted.')
    end

    def place_order
      authorize(:module, :purchasing_write?)
      return redirect_to(@purchase_order, alert: 'Only draft orders can be placed.') unless @purchase_order.draft?

      if @purchase_order.lines.empty?
        return redirect_to(@purchase_order, alert: 'Add at least one line before placing the order.')
      end

      @purchase_order.place_order!
      ActivityLogger.log('po_placed', subject: @purchase_order)
      redirect_to(@purchase_order, notice: "Order placed with #{@purchase_order.vendor.name}.")
    end

    # Record quantities received (partial allowed). Marks the order received
    # once everything has arrived.
    def receive
      authorize(:module, :purchasing_write?)
      received = params[:received]
      totals = received.respond_to?(:to_unsafe_h) ? received.to_unsafe_h : {}
      PurchaseReceiving.call(order: @purchase_order, totals: totals, token: params.require(:request_token), actor: Current.user)
      redirect_to(@purchase_order, notice: 'Delivery recorded. Source inventory was not changed.')
    rescue PurchaseReceiving::Error, ActiveRecord::RecordInvalid => e
      redirect_to(@purchase_order, alert: e.message)
    end

    def cancel
      authorize(:module, :purchasing_write?)
      @purchase_order.cancel! if @purchase_order.may_cancel?
      ActivityLogger.log('po_cancelled', subject: @purchase_order)
      redirect_to(@purchase_order, notice: 'Purchase order cancelled.')
    end

    # Draft-only: append a line to the order.
    def add_line
      authorize(:module, :purchasing_write?)
      return redirect_to(@purchase_order, alert: 'Only draft orders can be edited.') unless @purchase_order.draft?

      quantity = params[:quantity].to_s
      cost = params[:unit_cost].presence || '0'
      unless quantity.match?(/\A[1-9]\d*\z/) && quantity.to_i <= 2_147_483_647 && cost.match?(/\A\d+(?:\.\d{1,2})?\z/)
        return redirect_to(@purchase_order, alert: 'Enter a positive whole quantity and a nonnegative cost with at most two decimals.')
      end
      @purchase_order.lines.create!(
        sku: params[:sku].presence,
        name: params[:name].presence || 'Item',
        quantity: quantity.to_i,
        unit_cost_cents: (BigDecimal(cost) * 100).to_i
      )
      redirect_to(@purchase_order, notice: 'Line added.')
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RangeError => e
      redirect_to(@purchase_order, alert: e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : 'Quantity or cost is too large.')
    end

    # Draft-only: remove a line.
    def remove_line
      authorize(:module, :purchasing_write?)
      return redirect_to(@purchase_order, alert: 'Only draft orders can be edited.') unless @purchase_order.draft?

      @purchase_order.lines.find_by(id: params[:line_id])&.destroy
      redirect_to(@purchase_order, notice: 'Line removed.')
    end

    private

    def serialize_change
      Purchasing::PurchaseOrder.transaction do
        Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
        @purchase_order.reload
        yield
      end
    end

    def set_purchase_order
      @purchase_order = Purchasing::PurchaseOrder.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def purchase_order_params
      params.require(:purchase_order).permit(:vendor_id, :order_number, :expected_date, :notes)
    end

    def next_order_number
      "PO-#{Time.now.strftime('%Y%m')}-#{Purchasing::PurchaseOrder.count + 1}"
    end
  end
end
