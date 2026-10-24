# frozen_string_literal: true

class HomeController < AuthenticatedController
  before_action :require_dashboard_access, unless: :public_landing?

  def index
    return render('landing/index', layout: false) if public_landing?

    @widgets = DashboardWidget.entries(Current.user.dashboard_config_hash, user: Current.user)
    render('home/index')
  end

  # POST /dashboard/customize — save the user's widget layout to their profile.
  # Body: { widgets: [keys in display order], hidden: [keys] } or { reset: true }.
  def customize
    if params[:reset]
      Current.user.with_lock do
        Current.user.update!(dashboard_config: Current.user.dashboard_config_hash.except('widgets', 'hidden').presence)
      end
      return render(json: { ok: true, reset: true })
    end

    widgets = Array(params[:widgets])
    hidden = Array(params[:hidden])

    if (widgets + hidden).any? { |key| !DashboardWidget.allowed?(key, Current.user) }
      return render(json: { ok: false, error: 'Unknown or unavailable widget in layout' }, status: :unprocessable_entity)
    end

    Current.user.with_lock do
      Current.user.update!(dashboard_config: Current.user.dashboard_config_hash.merge('widgets' => widgets, 'hidden' => hidden))
    end
    render(json: { ok: true, widgets: widgets, hidden: hidden })
  rescue ActiveRecord::RecordInvalid => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  private

  # The iPhone app (Hotwire Native) never shows the marketing page: it has no Turbo, so the app
  # would wait on it forever. A signed-out app goes to the sign-in page like any other page.
  def public_landing?
    !WorkspaceNode.isolated? && Current.user.nil? && request.path == root_path && action_name == 'index' &&
      !hotwire_native_app?
  end

  def require_login
    super unless public_landing?
  end

  def require_dashboard_access
    head :forbidden unless Current.user&.can?('dashboard.read')
  end
end
