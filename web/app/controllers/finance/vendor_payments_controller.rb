# frozen_string_literal: true

module Finance
  # Record a payment to a vendor (accounts payable).
  class VendorPaymentsController < AuthenticatedController
    before_action :set_payment, only: %i[destroy restore]

    def index
      authorize(:module, :finance_read?)
      @range_days = params[:days].present? ? params[:days].to_i.clamp(7, 365) : 90
      @from = Date.current - (@range_days - 1)
      @through = Date.current
      active = Finance::VendorPayment.where(paid_on: @from..@through)
      @include_deleted = params[:include_deleted] == '1'
      @total_cents = active.sum(:amount_cents)
      @entry_count = active.count
      scope = @include_deleted ? active.with_discarded : active
      @removed_count = scope.count - @entry_count
      response.headers['Cache-Control'] = 'private, no-store'
      @pagy, @payments = pagy(scope.includes(:vendor).order(paid_on: :desc, created_at: :desc), items: 50)
    end

    def new
      authorize(:module, :finance_write?)
      @payment = Finance::VendorPayment.new(paid_on: Date.today, vendor_id: params[:vendor_id])
      @vendors = Purchasing::Vendor.ordered
    end

    def create
      authorize(:module, :finance_write?)
      @payment = Finance::VendorPayment.new(payment_params)
      if @payment.save
        ActivityLogger.log(
          'vendor_payment',
          subject: @payment.vendor,
          details: "$#{format('%.2f', @payment.amount_cents / 100.0)}"
        )
        redirect_to(finance_vendor_payments_path, notice: "Payment to #{@payment.vendor.name} recorded.")
      else
        @vendors = Purchasing::Vendor.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :finance_write?)
      @payment.discard
      ActivityLogger.log(
        'payment_deleted',
        subject: @payment.vendor,
        details: "$#{format('%.2f', @payment.amount_cents / 100.0)}"
      )
      redirect_to(finance_vendor_payments_path, notice: 'Payment removed.')
    end

    def restore
      authorize(:module, :finance_write?)
      @payment.undiscard
      ActivityLogger.log('payment_restored', subject: @payment.vendor)
      redirect_to(finance_vendor_payments_path, notice: 'Payment restored.')
    end

    private

    def set_payment
      @payment = Finance::VendorPayment.unscoped.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def payment_params
      params.require(:vendor_payment).permit(:vendor_id, :amount, :paid_on, :method, :reference, :notes)
    end
  end
end
