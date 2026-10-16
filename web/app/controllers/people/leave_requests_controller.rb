# frozen_string_literal: true

module People
  # Leave & PTO: employees request time off, managers approve or deny, and
  # balances track the annual allowance vs used hours.
  class LeaveRequestsController < AuthenticatedController
    before_action :set_leave_request, only: %i[show destroy approve deny cancel]

    def index
      authorize(:module, :leave_read?)
      @status = params[:status].presence || 'all'
      @requests = People::LeaveRequest.by_status(@status).recent(200).includes(:employee)
      @by_employee = People::LeaveRequest.pending.group(:employee_id).count
      @balances = People::LeaveBalance.for_year(Date.current.year).ordered.includes(:employee)
    end

    def show
      authorize(@leave_request)
      @balance = @leave_request.employee.leave_balances.find_by(leave_type: @leave_request.leave_type, year: @leave_request.starts_on.year)
    end

    def new
      authorize(:module, :leave_write?)
      @leave_request = People::LeaveRequest.new(starts_on: Date.today, ends_on: Date.today)
      @employees = People::Employee.active.ordered
    end

    def create
      authorize(:module, :leave_write?)
      @leave_request = People::LeaveRequest.new(leave_request_params)
      if @leave_request.save
        ActivityLogger.log('leave_requested', subject: @leave_request,
          details: "#{@leave_request.leave_type} · #{@leave_request.duration_label}")
        redirect_to(people_leave_request_path(@leave_request), notice: 'Leave request created.')
      else
        @employees = People::Employee.active.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :leave_write?)
      unless @leave_request.cancelled?
        return redirect_to(people_leave_request_path(@leave_request),
          alert: 'Cancelling is safer than deleting a request.')
      end

      @leave_request.destroy
      redirect_to(people_leave_requests_path, notice: 'Leave request removed.')
    end

    %i[approve deny cancel].each do |event|
      define_method(event) do
        authorize(:module, :leave_write?)
        LeaveRequestWorkflow.change(@leave_request, event)
        redirect_to people_leave_request_path(@leave_request), notice: 'Leave request updated.'
      end
    end

    private

    def set_leave_request
      @leave_request = People::LeaveRequest.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def leave_request_params
      params.require(:leave_request).permit(:employee_id, :leave_type, :starts_on, :ends_on, :hours, :reason)
    end
  end
end
