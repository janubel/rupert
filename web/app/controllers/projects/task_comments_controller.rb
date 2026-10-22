# frozen_string_literal: true

module Projects
  class TaskCommentsController < TaskChildrenController
    def create
      comment = @task.comments.new(body: params.dig(:comment, :body), user: Current.user)
      if comment.save
        ActivityLogger.log('task_commented', subject: @task)
        TaskNotifier.commented(@task, comment)
        back(notice: 'Comment added.', anchor: 'discussion')
      else
        failed(comment, anchor: 'discussion')
      end
    end
  end
end
