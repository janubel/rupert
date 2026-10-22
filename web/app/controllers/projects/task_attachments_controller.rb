# frozen_string_literal: true

module Projects
  class TaskAttachmentsController < TaskChildrenController
    # Anyone who can see the task may download its files; editing is for those who may edit it.
    skip_before_action :set_task, only: :show
    before_action :set_visible_task, only: :show

    def show
      authorize(@task, :show?)
      file = @task.attachments.find(params[:id])
      send_data(file.body, filename: file.filename, type: file.content_type, disposition: 'attachment')
    end

    def create
      upload = params[:file]
      return back(alert: 'Choose a file to attach.', anchor: 'files') unless upload.respond_to?(:read)

      file = Projects::TaskAttachment.from_upload(@task, upload, Current.user)
      if file.valid_upload? && file.save
        ActivityLogger.log('task_file_added', subject: @task, details: file.filename)
        back(notice: 'File attached.', anchor: 'files')
      else
        failed(file, anchor: 'files')
      end
    end

    def destroy
      file = @task.attachments.find(params[:id])
      file.destroy
      ActivityLogger.log('task_file_removed', subject: @task, details: file.filename)
      back(notice: 'File removed.', anchor: 'files')
    end

    private

    def set_visible_task
      @task = policy_scope(Projects::Task).find(params[:task_id])
    end
  end
end
