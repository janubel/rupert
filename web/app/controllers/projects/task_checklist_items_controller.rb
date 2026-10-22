# frozen_string_literal: true

module Projects
  class TaskChecklistItemsController < TaskChildrenController
    def create
      item = @task.checklist_items.new(title: params.dig(:item, :title))
      item.save ? back(anchor: 'checklist') : failed(item, anchor: 'checklist')
    end

    def update
      item = @task.checklist_items.find(params[:id])
      done = params.key?(:done) ? ActiveModel::Type::Boolean.new.cast(params[:done]) : !item.done
      item.update(done: done) ? back(anchor: 'checklist') : failed(item, anchor: 'checklist')
    end

    def destroy
      @task.checklist_items.find(params[:id]).destroy
      back(anchor: 'checklist')
    end
  end
end
