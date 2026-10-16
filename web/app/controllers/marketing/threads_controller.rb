# frozen_string_literal: true

module Marketing
  class ThreadsController < RecordsController
    def check_context
      thread = Thread.find(params[:id])
      thread.update!(lock_version: params.require(:lock_version), checked_at: Time.current)
      redirect_to(marketing_path, notice: 'Thread context checked for 7 days. Earlier reply approvals need a fresh review.')
    end

    def create
      super
    rescue ActiveRecord::RecordInvalid => error
      duplicate = Thread.find_by(url: Urls.canonical(record_params[:url]))
      raise error unless duplicate

      redirect_to(edit_marketing_thread_path(duplicate), alert: 'This thread is already saved. Review its existing reply before contacting it again.')
    end

    private

    def model = Thread
    def fields = %i[community_id url title excerpt status availability triage_note snoozed_until]
  end
end
