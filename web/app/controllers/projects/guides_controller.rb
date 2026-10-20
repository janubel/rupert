# frozen_string_literal: true

module Projects
  class GuidesController < AuthenticatedController
    def show
      authorize(Projects::Task, :index?)
    end
  end
end
