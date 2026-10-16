# frozen_string_literal: true

require 'csv'

class CustomersController < AuthenticatedController
  SORTS = {
    'recent' => [{ created_at: :desc, id: :desc }, 'Newest first'],
    'oldest' => [{ created_at: :asc, id: :asc }, 'Oldest first'],
    'name' => [%i[last_name first_name id], 'Name A–Z'],
    'email' => [%i[email id], 'Email A–Z']
  }.freeze

  before_action :set_customer, only: %i[show edit update]

  def index
    authorize(:module, :customers_read?)

    @directory_states = DirectorySyncState.where(kind: 'customers').index_by(&:provider)
    @q = filtered_customers.ransack(params[:q])
    @due_follow_ups = CustomerFollowUp.due.includes(:customer, :owner).order(:due_on, :id).limit(20)
    @due_count = CustomerFollowUp.due.count
    @owners = crm_owners
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : 'recent'
    @pagy, @customers = pagy(@q.result.distinct.order(SORTS.fetch(@sort).first), items: 25)
    @status_counts = Core::Customer.group(:crm_status).count
    @total_customers = @status_counts.values.sum
    @filtered = filters_active?
    # One grouped SUM + one grouped COUNT for the page instead of a lifetime-
    # value query and an orders COUNT per row (the view calls orders.size).
    ids = @customers.map(&:id)
    @lifetime_totals = Core::Order.where(customer_id: ids).group(:customer_id, :currency).sum(:gross_cents)
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
    @directory_states = DirectorySyncState.where(kind: 'customers').index_by(&:provider)
    @last_order_at = @customer.orders.maximum(:occurred_at)
    @open_follow_up_count = @customer.follow_ups.open.count
    @overdue_follow_up_count = @customer.follow_ups.due.where(due_on: ...Date.current).count
    @pagy, @orders = pagy(@customer.orders.order(occurred_at: :desc, id: :desc), items: 25)
    @interactions_pagy, @interactions = pagy(@customer.interactions.includes(:author).order(created_at: :desc, id: :desc), items: 25, page_param: :activity_page)
    @follow_ups_pagy, @follow_ups = pagy(@customer.follow_ups.includes(:owner).order(Arel.sql('CASE WHEN completed_at IS NULL THEN 0 ELSE 1 END'), :due_on, :id), items: 25, page_param: :follow_up_page)
    @owners = crm_owners
  end

  def new
    authorize(:module, :customers_write?)
    @customer = Core::Customer.new(source: 'manual')
    @owners = crm_owners
  end

  def create
    authorize(:module, :customers_write?)
    @owners = crm_owners
    @customer = Core::Customer.new(customer_params)
    @customer.source = 'manual'
    @customer.external_id = "manual:#{SecureRandom.hex(8)}"

    if @customer.save
      redirect_to(customer_path(@customer), notice: 'Customer added.')
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    authorize(@customer)
    @owners = crm_owners
  end

  def update
    authorize(@customer)
    @owners = crm_owners
    if @customer.update(customer_params)
      redirect_to(customer_path(@customer), notice: 'Customer updated.')
    else
      render(:edit, status: :unprocessable_entity)
    end
  end

  def export
    authorize(:module, :customers_write?)
    records = filtered_customers.ransack(params[:q]).result.distinct.order(:id)
    if records.count > 25_000
      return redirect_to(customers_path, alert: 'Narrow your filters to 25,000 profiles or fewer before exporting.')
    end
    csv = CSV.generate do |rows|
      rows << %w[source external_id first_name last_name preferred_name email phone crm_status tags]
      records.find_each do |customer|
        rows << %i[source external_id first_name last_name preferred_name email phone crm_status tags].map do |key|
          value = customer.public_send(key).to_s
          value.match?(/\A[\s]*[=+@-]/) ? "'#{value}" : value
        end
      end
    end
    response.headers['Cache-Control'] = 'no-store'
    send_data(csv, filename: "rupert-customers-#{Date.current.iso8601}.csv", type: 'text/csv')
  end

  private

  # Staff who lack customers.read get an explanation instead of a bare redirect;
  # write-permission denials keep the standard behaviour.
  def user_not_authorized
    return super if Current.user&.can?('customers.read')

    render('customers/no_access', status: :forbidden)
  end

  def filters_active?
    q = params[:q].respond_to?(:values) ? params[:q].values.any?(&:present?) : false
    q || %i[status source owner due directory].any? { |key| params[key].present? }
  end

  def filtered_customers
    records = Core::Customer.all
    records = records.where(crm_status: params[:status]) if Core::Customer::CRM_STATUSES.include?(params[:status])
    records = records.where(source: params[:source]) if Core::Customer::SOURCES.include?(params[:source])
    records = records.where(owner_id: Current.user.id) if params[:owner] == 'mine'
    records = records.where(owner_id: nil) if params[:owner] == 'unassigned'
    records = records.where(id: CustomerFollowUp.due.select(:customer_id)) if params[:due] == '1'
    records = records.where(id: verified_customers.select(:id)) if params[:directory] == 'verified'
    records = records.where.not(source: 'manual').where.not(id: verified_customers.select(:id)) if params[:directory] == 'historical'
    records
  end

  def verified_customers
    DirectorySyncState.where(kind: 'customers').where.not(last_success_at: nil).map do |state|
      Core::Customer.where(source: state.provider, source_synced_at: state.last_success_at)
    end.reduce(Core::Customer.none, :or)
  end

  def crm_owners
    User.where(tenant_id: Current.tenant_id).active.ordered.select { |user| user.can?('customers.read') }
  end

  def set_customer
    @customer = Core::Customer.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  def customer_params
    attributes = params.require(:customer).permit(:preferred_name, :crm_status, :tags, :owner_id, :notes)
    if !@customer || @customer.source == 'manual'
      attributes.merge!(params.require(:customer).permit(:first_name, :last_name, :email, :phone))
    end
    attributes
  end
end
