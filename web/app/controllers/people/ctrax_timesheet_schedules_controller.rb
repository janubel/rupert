# frozen_string_literal: true

module People
  class CtraxTimesheetSchedulesController < AuthenticatedController
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def update
      raise Pundit::NotAuthorizedError unless CtraxLaborSync.authorized_actor(Current.user.id)
      return head :unprocessable_entity unless %w[1 0].include?(params[:enabled])

      enabled = params[:enabled] == '1'
      CtraxLaborSync.configure!(enabled: enabled, actor: Current.user)
      redirect_to people_ctrax_timesheets_path, notice: enabled ? 'Automatic C-Trax timecard refresh enabled. Check the next scheduled slot and read status below.' : 'Automatic C-Trax timecard refresh disabled. Retained history remains available.'
    rescue Ctrax::LaborImport::Error => error
      redirect_to people_ctrax_timesheets_path, alert: error.message
    end
  end
end
