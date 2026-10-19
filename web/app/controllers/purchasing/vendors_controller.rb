# frozen_string_literal: true

module Purchasing
  # Vendor directory: who the shop buys from.
  class VendorsController < AuthenticatedController
    before_action -> { authorize(:module, :purchasing_read?) }
    before_action :set_vendor, only: %i[show edit update destroy]

    def index
      authorize(:module, :purchasing_read?)
      @q = params[:q].to_s.strip
      @vendors = Purchasing::Vendor.search(@q).ordered.includes(:purchase_orders)
    end

    def show
      authorize(:module, :purchasing_read?)
      @purchase_orders = @vendor.purchase_orders.order(created_at: :desc)
    end

    def new
      authorize(:module, :purchasing_write?)
      @vendor = Purchasing::Vendor.new
    end

    def create
      authorize(:module, :purchasing_write?)
      @vendor = Purchasing::Vendor.new(vendor_params)
      if @vendor.save
        redirect_to(@vendor, notice: 'Vendor added.')
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :purchasing_write?)
    end

    def update
      authorize(:module, :purchasing_write?)
      if @vendor.update(vendor_params)
        redirect_to(@vendor, notice: 'Vendor updated.')
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :purchasing_write?)
      @vendor.destroy
      redirect_to(vendors_path, notice: 'Vendor removed.')
    rescue ActiveRecord::DeleteRestrictionError
      redirect_to(@vendor, alert: "Vendor has purchase orders and can't be removed.")
    end

    private

    def set_vendor
      @vendor = Purchasing::Vendor.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def vendor_params
      params.require(:vendor).permit(:name, :email, :phone, :contact_name, :address, :notes, :payment_terms)
    end
  end
end
