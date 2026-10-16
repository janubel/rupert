# frozen_string_literal: true

module Api
  module V1
    # Employee credentials have no catalog, ERP, or administrator scopes.
    class EmployeeBaseController < ActionController::API
      around_action :isolated_context
      before_action :authenticate_employee
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from Pundit::NotAuthorizedError, with: :forbidden
      rescue_from TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, AASM::InvalidTransition, ActiveRecord::StaleObjectError, with: :invalid
      rescue_from ActionController::ParameterMissing, with: :invalid

      private

      def isolated_context
        Current.reset
        response.headers['Cache-Control'] = 'no-store'
        yield
      ensure
        Current.reset
      end

      def authenticate_employee
        secret = request.headers['Authorization'].to_s.match(/\ABearer (\S+)\z/i)&.captures&.first
        @employee_session = EmployeeAppSession.authenticate(secret)
        unless @employee_session
          response.headers['WWW-Authenticate'] = 'Bearer realm="Rupert Employee"'
          return render json: { error: 'unauthorized' }, status: :unauthorized
        end
        Current.user = @employee_session.user
        Current.tenant = @employee_session.tenant
      end

      def not_found
        render json: { error: 'not_found' }, status: :not_found
      end

      def forbidden
        render json: { error: 'forbidden' }, status: :forbidden
      end

      def invalid(error)
        message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
        render json: { error: 'invalid_request', message: message }, status: :unprocessable_entity
      end

      def worker
        @employee_session.employee
      end
    end
  end
end
