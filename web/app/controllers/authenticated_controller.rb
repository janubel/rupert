# frozen_string_literal: true

# Base controller for signed-in, tenant-scoped pages. Includes Pundit so every
# action can authorize against a policy, and the shared nav is built from the
# module registry.
class AuthenticatedController < ApplicationController
  include Pundit::Authorization
  include Pagy::Backend

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  # Records that someone took data out of Rupert (CSV, original, backup).
  # Never raises; the details name the export, not its contents.
  def log_export(label, details = nil)
    ActivityLogger.log('data_exported', details: [label, details].compact.join(': '))
  end

  def pundit_user
    Current.user
  end

  def user_not_authorized(error = nil)
    @ops_denied = { via: 'pundit', policy: error.try(:policy)&.class&.name, query: error.try(:query)&.to_s }.compact
    flash[:alert] = "You don't have permission to do that."
    redirect_back(fallback_location: root_path)
  end
end
