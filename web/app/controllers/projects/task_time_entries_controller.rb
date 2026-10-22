# frozen_string_literal: true

module Projects
  class TaskTimeEntriesController < TaskChildrenController
    def create
      entry = @task.time_entries.new(entry_params.merge(user: Current.user))
      entry.minutes = Projects::TaskTimeEntry.parse_minutes(params.dig(:entry, :hours))
      entry.logged_on ||= Date.current
      if entry.minutes && entry.save
        ActivityLogger.log('task_time_logged', subject: @task, details: "#{entry.minutes} minutes")
        back(notice: 'Time logged.', anchor: 'time')
      else
        entry.errors.add(:base, 'Enter the time as hours (1.5), 1:30, 90m or 2h') if entry.minutes.nil?
        failed(entry, anchor: 'time')
      end
    end

    def destroy
      entry = @task.time_entries.find(params[:id])
      return back(alert: 'You can remove only your own time.', anchor: 'time') unless own_or_manager?(entry)

      entry.destroy
      back(notice: 'Time entry removed.', anchor: 'time')
    end

    private

    def own_or_manager?(entry)
      entry.user_id.to_s == Current.user.id.to_s || Current.user.can?('projects.write')
    end

    def entry_params
      params.require(:entry).permit(:logged_on, :note)
    end
  end
end
