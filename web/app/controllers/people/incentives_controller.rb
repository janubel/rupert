# frozen_string_literal: true

module People
  # Incentives model: try a commission plan with sliders against real shifts and sales (IncentiveModel). Read-only:
  # nothing is saved or posted to payroll. The plan lives in the address, so a link shares the exact scenario.
  class IncentivesController < AuthenticatedController
    def show
      authorize(:module, :payroll_read?)
      @plan = IncentiveModel.plan_from(params.permit(:shift_rate, :training_rate, :training_hours, trainees: []).to_h.symbolize_keys)
      @model = IncentiveModel.new(plan: @plan, period: params[:period], from: params[:from], to: params[:to])
    end
  end
end
