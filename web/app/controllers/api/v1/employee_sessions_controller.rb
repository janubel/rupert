# frozen_string_literal: true

module Api
  module V1
    class EmployeeSessionsController < EmployeeBaseController
      skip_before_action :authenticate_employee, only: :create
      def create
        email = params[:email].to_s.strip.downcase
        if LoginThrottle.blocked?(ip: request.remote_ip, email: email)
          return render json: { error: 'rate_limited' }, status: :too_many_requests
        end
        user = User.find_by(email: email)
        host_tenant = Tenant.find_by(subdomain: request.subdomain)
        if user&.active? && user.tenant&.status == 'active' && (!host_tenant || host_tenant.id == user.tenant_id) && user.authenticate(params[:password])
          Current.user = user
          record, token = EmployeeAppSession.issue!(user: user, device_name: params[:device_name].presence || 'Rupert app')
          AccessLogger.record(source: 'password', status: 'success', request: request, user: user, detail: 'employee app')
          render json: { token: token, expires_at: record.expires_at.iso8601, employee: { id: record.employee_id, name: record.employee.name }, workspace: { name: Current.tenant.name } }, status: :created
        else
          AccessLogger.record(source: 'password', status: 'failure', request: request, email: email, detail: 'invalid employee credentials')
          render json: { error: 'invalid_credentials' }, status: :unauthorized
        end
      end

      def show
        render json: { employee: { id: worker.id, name: worker.name }, workspace: { name: Current.tenant.name }, expires_at: @employee_session.expires_at.iso8601 }
      end

      def destroy
        @employee_session.update!(revoked_at: Time.current)
        head :no_content
      end
    end
  end
end
