# frozen_string_literal: true

class CustomersController < AuthenticatedController
  before_action :set_customer, only: %i[show edit update]

  def index
    authorize(:module, :customers_read?)

    @q = Core::Customer.ransack(params[:q])
    @pagy, @customers = pagy(@q.result.order(created_at: :desc, id: :desc), items: 25)
    # One grouped SUM + one grouped COUNT for the page instead of a lifetime-
    # value query and an orders COUNT per row (the view calls orders.size).
    ids = @customers.map(&:id)
    @lifetime_totals = Core::Order.where(customer_id: ids).group(:customer_id).sum(:gross_cents)
    @order_counts = Core::Order.where(customer_id: ids).group(:customer_id).count
  end

  def sync_directory
    authorize(:module, :customers_write?)
    authorize(:module, :sync_write?)
    Directories::Sync::PAIRS.each do |provider, kinds|
      next unless kinds.include?('customers') && Directories::Sync.available?(provider)

      DirectorySyncJob.perform_later(Current.tenant_id, provider, 'customers', manual: true)
    end
    redirect_to(customers_path, notice: 'Customer directory sync queued. Refresh to see the latest read status.')
  end

  def show
    authorize(@customer)
    @orders = @customer.orders.order(occurred_at: :desc).limit(50)
  end

  def new
    authorize(:module, :customers_write?)
    @customer = Core::Customer.new(source: 'manual')
  end

  def create
    authorize(:module, :customers_write?)
    @customer = Core::Customer.new(customer_params)
    @customer.source = 'manual'
    @customer.external_id = "manual:#{SecureRandom.hex(8)}"

    if @customer.save
      redirect_to(@customer, notice: 'Customer added.')
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    authorize(@customer)
  end

  def update
    authorize(@customer)
    if @customer.update(customer_params)
      redirect_to(@customer, notice: 'Customer updated.')
    else
      render(:edit, status: :unprocessable_entity)
    end
  end

  private

  def set_customer
    @customer = Core::Customer.find(params[:id])
  end

  def customer_params
    params.require(:customer).permit(:first_name, :last_name, :email, :phone, :notes)
  end
end
