# frozen_string_literal: true

# Lets an admin hide the "update available" banner for the build it is about.
class UpdateNoticesController < AuthenticatedController
  def dismiss
    session[:dismissed_update_for] = BuildInfo.current.revision
    redirect_back(fallback_location: root_path)
  end
end
