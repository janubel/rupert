# frozen_string_literal: true

class EmployeeAppController < ApplicationController
  skip_before_action :require_login, only: %i[show privacy manifest service_worker]
  # This public script contains no session or employee data. Rails otherwise
  # rejects non-XHR JavaScript responses, including service worker registration.
  skip_after_action :verify_same_origin_request, only: :service_worker
  before_action -> { require_login if Current.user }, only: :show

  def privacy
  end

  def show
    response.headers['Cache-Control'] = 'no-store'
    @sessions = Current.user ? EmployeeAppSession.where(user_id: Current.user.id, revoked_at: nil).where('expires_at > ?', Time.current).order(created_at: :desc) : []
  end

  def revoke
    record = EmployeeAppSession.find_by!(id: params[:id], user_id: Current.user.id)
    record.update!(revoked_at: Time.current)
    redirect_to employee_app_path, notice: 'Device signed out.'
  end

  def manifest
    render json: { id: '/employee', name: 'Rupert Employee', short_name: 'Rupert', start_url: '/employee', scope: '/', display: 'standalone',
      background_color: '#f6f3eb', theme_color: '#526145', icons: [192, 512].map { |size| { src: "/employee/icon-#{size}.png", sizes: "#{size}x#{size}", type: 'image/png', purpose: 'any maskable' } } }, content_type: 'application/manifest+json'
  end

  def service_worker
    response.headers['Service-Worker-Allowed'] = '/'
    response.headers['Cache-Control'] = 'no-cache'
    send_file Rails.root.join('app/javascript/employee_service_worker.js'), type: 'application/javascript', disposition: 'inline'
  end
end
