# frozen_string_literal: true

# Base controller for signed-in, tenant-scoped pages. Includes Pundit so every
# action can authorize against a policy, and the shared nav is built from the
# module registry.
class AuthenticatedController < ApplicationController
  include Pundit::Authorization
  include Pagy::Method

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
  before_action :note_presence

  # Pagy 43 removed the legacy :last_page overflow option. Preserve the app's
  # existing behavior by retrying an out-of-range request at that paginator's
  # last page, without redirecting or discarding active filters.
  def pagy(paginator, collection, **options)
    super
  rescue Pagy::RangeError => error
    super(paginator, collection, **options.merge(page: error.pagy.last))
  end

  private

  # Records that someone took data out of Rupert (CSV, original, backup).
  # Never raises; the details name the export, not its contents.
  def log_export(label, details = nil)
    ActivityLogger.log('data_exported', details: [label, details].compact.join(': '))
  end

  # "Recently active" in team chat: a page view counts (at most one write a minute).
  def note_presence
    return unless request.get? && request.format.html?
    # Previews (an administrator viewing employee screens) write nothing.
    return if controller_name == 'employee_preview' || params[:preview].to_s == '1'

    TeamChat::Presence.touch(Current.user)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[presence] #{e.class}")
  end

  def pundit_user
    Current.user
  end

  def user_not_authorized
    flash[:alert] = "You don't have permission to do that."
    redirect_back(fallback_location: root_path)
  end
end
