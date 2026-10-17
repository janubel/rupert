# frozen_string_literal: true

module Finance
  # Record a payment to a vendor (accounts payable).
  class VendorPaymentsController < AuthenticatedController
    include ApprovedPeriodNotice
    include FinanceRegister
    before_action :set_payment, only: %i[destroy restore]

    def index
      authorize(:module, :finance_read?)
      @from, @through = register_window
      @q = params[:q].to_s.strip.first(100)
      @min_cents = register_cents(params[:min])
      @max_cents = register_cents(params[:max])
      @filter_problem = amount_filter_problem
      active = Finance::VendorPayment.where(paid_on: @from..@through)
      active = search(active)
      active = active.where('vendor_payments.amount_cents >= ?', @min_cents) if @min_cents
      active = active.where('vendor_payments.amount_cents <= ?', @max_cents) if @max_cents
      @include_deleted = params[:include_deleted] != '0'
      @total_cents = active.sum(:amount_cents)
      @entry_count = active.count
      scope = @include_deleted ? active.with_discarded : active
      @removed_count = scope.count - @entry_count
      response.headers['Cache-Control'] = 'private, no-store'
      ordered = scope.includes(:vendor).order(paid_on: :desc, created_at: :desc)
      if request.format.csv?
        send_data payments_csv(ordered), filename: "vendor-payments-#{@from}-#{@through}.csv", type: 'text/csv'
        return
      end
      @pagy, @payments = pagy(ordered, items: 50)
      @activity = register_activity('Finance::VendorPayment', @payments.map(&:id))
      @locks = register_locks
      @can_write = Current.user.can?('finance.write')
    end

    def new
      authorize(:module, :finance_write?)
      @payment = Finance::VendorPayment.new(paid_on: Date.current, vendor_id: params[:vendor_id])
      @vendors = Purchasing::Vendor.ordered
    end

    def create
      authorize(:module, :finance_write?)
      @payment = Finance::VendorPayment.new(payment_params)
      if @payment.save
        note_approved_period(@payment.paid_on, 'Vendor payment')
        ActivityLogger.log(
          'vendor_payment',
          subject: @payment,
          details: "#{helpers.finance_money_text(@payment.amount_cents)} to #{@payment.vendor.name} dated #{@payment.paid_on}"
        )
        redirect_to(finance_vendor_payments_path, notice: "Payment to #{@payment.vendor.name} recorded.")
      else
        @vendors = Purchasing::Vendor.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :finance_write?)
      return redirect_to(finance_vendor_payments_path, alert: @payment.errors.full_messages.to_sentence.presence || 'Nothing was changed.') unless @payment.discard

      note_approved_period(@payment.paid_on, 'Vendor payment')
      ActivityLogger.log(
        'payment_deleted',
        subject: @payment,
        details: "#{helpers.finance_money_text(@payment.amount_cents)} to #{@payment.vendor.name} dated #{@payment.paid_on}"
      )
      redirect_to(finance_vendor_payments_path, notice: 'Payment removed.')
    end

    def restore
      authorize(:module, :finance_write?)
      return redirect_to(finance_vendor_payments_path, alert: @payment.errors.full_messages.to_sentence.presence || 'Nothing was changed.') unless @payment.undiscard

      note_approved_period(@payment.paid_on, 'Vendor payment')
      ActivityLogger.log('payment_restored', subject: @payment,
        details: "#{helpers.finance_money_text(@payment.amount_cents)} to #{@payment.vendor.name} dated #{@payment.paid_on}")
      redirect_to(finance_vendor_payments_path, notice: 'Payment restored.')
    end

    private

    def search(scope)
      return scope if @q.blank?

      like = register_like(@q)
      scope.left_joins(:vendor).where(
        'LOWER(vendors.name) LIKE :q OR LOWER(vendor_payments.reference) LIKE :q OR LOWER(vendor_payments.notes) LIKE :q', q: like
      )
    end

    def amount_filter_problem
      if params[:min].present? && @min_cents.nil? || params[:max].present? && @max_cents.nil?
        'An amount filter was ignored: enter dollars as digits with up to two decimals, for example 25.50.'
      elsif @min_cents && @max_cents && @min_cents > @max_cents
        'The minimum amount is larger than the maximum, so nothing can match.'
      end
    end

    def payments_csv(payments)
      require 'csv'
      safe = FinanceHelper.method(:csv_safe)
      CSV.generate do |csv|
        csv << %w[Date Vendor Method Amount Currency Reference Notes State]
        payments.each do |payment|
          csv << [payment.paid_on, safe.call(payment.vendor&.name), payment.method,
                  FinanceHelper.cents_to_decimal(payment.amount_cents), 'USD',
                  safe.call(payment.reference), safe.call(payment.notes), payment.discarded? ? 'Removed' : 'Active']
        end
      end
    end

    def set_payment
      @payment = Finance::VendorPayment.unscoped.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def payment_params
      params.require(:vendor_payment).permit(:vendor_id, :amount, :paid_on, :method, :reference, :notes)
    end
  end
end
