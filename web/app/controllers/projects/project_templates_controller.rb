# frozen_string_literal: true

module Projects
  class ProjectTemplatesController < AuthenticatedController
    def destroy
      authorize(:module, :projects_write?)
      template = Projects::ProjectTemplate.find(params[:id])
      template.destroy
      ActivityLogger.log('project_template_deleted', details: template.name)
      redirect_to(new_projects_project_path, notice: "Template “#{template.name}” deleted.")
    end
  end
end
