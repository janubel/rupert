# frozen_string_literal: true

module People
  # HR employee records: the directory, org placement, and employment lifecycle.
  class EmployeesController < AuthenticatedController
    before_action :set_employee, only: %i[show edit update destroy transition]
    before_action :set_org_data, only: %i[new create edit update]

    def index
      authorize(:module, :hr_read?)
      @q = params[:q].to_s.strip
      @status = params[:status].presence || 'all'
      @employees = People::Employee.by_status(@status).ordered
      if @q.present?
        @employees = @employees.where(
          SearchSql.contains_any(%w[first_name last_name employee_number email]), *Array.new(4, "%#{@q}%")
        )
      end
      @employees = @employees.includes(:department, :position).limit(200)
      @by_department = People::Employee.active.group(:department_id).count
      @pending_leave = People::LeaveRequest.pending.count if Current.user.can?('leave.read')
      @awaiting_timesheets = People::Timesheet.awaiting_review.count if Current.user.can?('timesheets.read')
    end

    def sync_directory
      authorize(:module, :hr_write?)
      authorize(:module, :sync_write?)
      if Directories::Sync.available?('ctrax')
        DirectorySyncJob.perform_later(Current.tenant_id, 'ctrax', 'employees', manual: true)
        redirect_to(people_employees_path, notice: 'C-Trax employee directory sync queued. Refresh to see the latest read status.')
      else
        redirect_to(people_employees_path, alert: 'Configure the authorized C-Trax connection first.')
      end
    end

    def show
      authorize(@employee)
      @timesheets = @employee.timesheets.recent(12) if Current.user.can?('timesheets.read')
      @leave_balances = @employee.leave_balances.for_year(Date.current.year).ordered if Current.user.can?('leave.read')
      @leave_requests = @employee.leave_requests.recent(12) if Current.user.can?('leave.read')
      @pay_rates = @employee.pay_rates.recent if Current.user.can?('payroll.read')
      @payslips = @employee.payslips.order(id: :desc).limit(12) if Current.user.can?('payroll.read')
    end

    def new
      authorize(:module, :hr_write?)
      @employee = People::Employee.new(hire_date: Date.today, employee_number: next_employee_number)
    end

    def create
      authorize(:module, :hr_write?)
      @employee = People::Employee.new(employee_params)
      if @employee.save
        ActivityLogger.log('employee_hired', subject: @employee, details: @employee.department&.name)
        redirect_to(people_employee_path(@employee), notice: "#{@employee.name} added.")
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :hr_write?)
    end

    def update
      authorize(:module, :hr_write?)
      if @employee.update(employee_params)
        ActivityLogger.log('employee_updated', subject: @employee, details: @employee.status)
        redirect_to(people_employee_path(@employee), notice: "#{@employee.name} updated.")
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :hr_write?)
      if @employee.active?
        return redirect_to(people_employee_path(@employee),
          alert: 'Terminate the employee instead of deleting the record.')
      end

      @employee.destroy
      ActivityLogger.log('employee_record_removed', subject: @employee)
      redirect_to(people_employees_path, notice: 'Employee record removed.')
    end

    # POST /people/employees/:id/transition?event=place_on_leave|return_to_work|terminate|rehire
    def transition
      authorize(:module, :hr_write?)
      event = params[:event]
      if %w[place_on_leave return_to_work terminate
            rehire].include?(event) && @employee.public_send("may_#{event}?")
        @employee.send("#{event}!")
        @employee.update!(termination_date: event == 'terminate' ? Date.today : nil) if %w[terminate
                                                                                           rehire].include?(event)
        ActivityLogger.log("employee_#{event}", subject: @employee)
        redirect_to(people_employee_path(@employee), notice: "#{@employee.name} #{event.tr('_', ' ')}d.")
      else
        redirect_to(people_employee_path(@employee),
          alert: "Cannot #{event.tr('_', ' ')} a #{@employee.status} employee.")
      end
    end

    private

    def set_employee
      @employee = People::Employee.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def set_org_data
      @departments = People::Department.ordered
      @positions = People::Position.ordered
      @users = User.where(tenant_id: Current.tenant_id).active.ordered
    end

    def next_employee_number
      year = Time.now.year
      count = People::Employee.unscoped.where(tenant_id: Current.tenant_id).count + 1
      "E#{year}-#{count.to_s.rjust(3, '0')}"
    end

    def employee_params
      params.require(:employee).permit(
        :user_id,
        :department_id,
        :position_id,
        :employee_number,
        :first_name,
        :last_name,
        :legal_name,
        :email,
        :phone,
        :address,
        :date_of_birth,
        :hire_date,
        :termination_date,
        :employment_type,
        :emergency_contact_name,
        :emergency_contact_phone,
        :notes
      )
    end
  end
end
