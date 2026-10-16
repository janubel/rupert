# frozen_string_literal: true

module Api
  module V1
    class EmployeeClockController < EmployeeBaseController
      rescue_from TimeClockService::Error, with: :invalid
      def index
        render json: { data: ClockShift.where(employee_id: worker.id, user_id: Current.user.id).recent.limit(100).as_json(only: %i[id started_at ended_at]) }
      end

      def create
        shift = TimeClockService.clock_in(user: Current.user, request_token: params[:request_token].to_s)
        render json: { data: shift.as_json(only: %i[id started_at ended_at]) }, status: :created
      end

      def update
        shift = TimeClockService.clock_out(user: Current.user, shift_id: params[:id])
        render json: { data: shift.as_json(only: %i[id started_at ended_at]) }
      end

      def correction
        record = TimeClockService.request_correction(user: Current.user, shift_id: params[:id],
          attributes: params.require(:clock_correction).permit(:proposed_started_at, :proposed_ended_at, :reason).to_h.symbolize_keys)
        render json: { data: record.as_json(only: %i[id status reason proposed_started_at proposed_ended_at]) }, status: :created
      end
    end
  end
end
