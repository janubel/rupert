# frozen_string_literal: true

module People
  # HR employee records: the directory, org placement, and employment lifecycle.
  class EmployeesController < AuthenticatedController
    before_action :set_employee, only: %i[show edit update destroy transition add_pay_rate set_leave_allowance]
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
      if Directories::Sync::PAIRS.key?(params[:source])
        @employees = @employees.where(source: params[:source]).or(
          @employees.where(id: EmployeeSourceIdentity.where(source: params[:source]).select(:employee_id))
        )
      end
      @employees = @employees.where(user_id: nil) if params[:login] == 'missing'
      @employees = @employees.where.not(user_id: nil) if params[:login] == 'linked'
      @missing_logins = People::Employee.active.where(user_id: nil).count
      @pagy, @employees = pagy(@employees.includes(:department, :position, :user, :source_identities).order(:id), items: 50)
      @by_department = People::Employee.active.group(:department_id).count
      @pending_leave = People::LeaveRequest.pending.count if Current.user.can?('leave.read')
      @awaiting_timesheets = People::Timesheet.awaiting_review.count if Current.user.can?('timesheets.read')
    end

    def sync_directory
      authorize(:module, :hr_write?)
      authorize(:module, :sync_write?)
      queued = Directories::Sync::PAIRS.filter_map do |provider, kinds|
        next unless kinds.include?('employees') && Directories::Sync.available?(provider)

        DirectorySyncJob.perform_later(Current.tenant_id, provider, 'employees', manual: true)
        provider
      end
      if queued.any?
        redirect_to(people_employees_path, notice: 'Employee directory reads queued. Refresh to review source coverage and access status.')
      else
        redirect_to(people_employees_path, alert: 'Configure an authorized directory connection first.')
      end
    end

    def consolidation
      authorize(:module, :hr_write?)
      raise Pundit::NotAuthorizedError unless Current.user.can_manage_accounts?
      @employees = People::Employee.includes(:source_identities, :user).ordered
    end

    def consolidate
      authorize(:module, :hr_write?)
      raise Pundit::NotAuthorizedError unless Current.user.can_manage_accounts?
      employee = EmployeeConsolidation.call(primary_id: params[:primary_id], duplicate_ids: params[:duplicate_ids], reason: params[:reason])
      redirect_to people_employee_path(employee), notice: 'Profiles consolidated. Source identities and HR history were retained; old setup links and app sessions were revoked.'
    rescue EmployeeConsolidation::Error, ActiveRecord::RecordInvalid => error
      redirect_to consolidation_people_employees_path, alert: error.message
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

      unless @employee.destroy
        return redirect_to people_employee_path(@employee), alert: @employee.errors.full_messages.to_sentence
      end
      ActivityLogger.log('employee_record_removed', subject: @employee)
      redirect_to(people_employees_path, notice: 'Employee record removed.')
    rescue ActiveRecord::DeleteRestrictionError
      redirect_to people_employee_path(@employee), alert: 'Retain employees with linked source identities and their history.'
    end

    def add_pay_rate
      authorize(:module, :payroll_write?)
      attributes = params.require(:pay_rate).permit(:pay_type, :pay_frequency, :effective_on, :ended_on)
      amount = params.require(:pay_rate)[:amount].to_s.strip
      raise ArgumentError, 'Enter a positive USD amount with at most two decimal places.' unless amount.match?(/\A\d{1,8}(?:\.\d{1,2})?\z/)
      cents = (BigDecimal(amount) * 100).to_i
      raise ArgumentError, 'Enter a positive supported pay amount.' unless (1..2_000_000_000).cover?(cents)
      attributes[attributes[:pay_type] == 'salary' ? :annual_salary_cents : :hourly_rate_cents] = cents
      Tenant.transaction do
        Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
        @employee.pay_rates.create!(attributes)
        ActivityLogger.log('employee_pay_rate_added', subject: @employee, details: 'Effective-dated pay rate added; earlier records retained.')
      end
      redirect_to people_employee_path(@employee), notice: 'Pay rate saved.'
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      redirect_to people_employee_path(@employee), alert: error.message
    end

    def set_leave_allowance
      authorize(:module, :leave_write?)
      attributes = params.require(:leave_allowance).permit(:leave_type, :year, :accrued_hours)
      Tenant.transaction do
        Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
        balance = @employee.leave_balances.find_or_initialize_by(leave_type: attributes[:leave_type], year: attributes[:year])
        balance.update!(accrued_hours: attributes[:accrued_hours])
        ActivityLogger.log('employee_leave_allowance_set', subject: @employee, details: 'Recorded leave allowance updated; used hours preserved.')
      end
      redirect_to people_employee_path(@employee), notice: 'Leave allowance saved.'
    rescue ActiveRecord::RecordInvalid => error
      redirect_to people_employee_path(@employee), alert: error.record.errors.full_messages.to_sentence
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
      record = People::Employee.unscoped.find_by!(tenant_id: Current.tenant_id, id: params[:id])
      if record.merged_into_id
        redirect_to people_employee_path(record.merged_into_id), status: :see_other
      else
        @employee = record
      end
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
