# frozen_string_literal: true

class InstanceSessionsController < ApplicationController
  skip_before_action :require_login, only: :create
  skip_forgery_protection only: :create
  before_action { response.headers['Cache-Control'] = 'no-store' }
  def create
    return head :not_found unless WorkspaceNode.isolated?
    # Cross-origin form is deliberate; the token is a one-use credential and
    # only the configured control-plane origin may initiate the exchange.
    return head :forbidden unless request.headers['Origin'] == WorkspaceNode.control_origin
    claims = WorkspaceNode.exchange(params[:handoff].to_s)
    return head :forbidden unless claims['workspace_id'] == ENV['RUPERT_WORKSPACE_ID'] && claims['tenant_id'] == ENV['RUPERT_TENANT_ID']
    tenant = Tenant.find(claims['tenant_id'])
    if claims['support_grant_id']
      user = User.find_or_initialize_by(email: "support-#{claims.fetch('user_id').to_i}@support.invalid")
      user.assign_attributes(tenant: tenant, name: 'Authorized support', role: 'admin', active: true)
      user.password = SecureRandom.hex(32) if user.new_record?
      user.save!
      start_browser_session(user, method: 'instance_support')
      session[:instance_support_grant_id] = claims['support_grant_id']
      session[:instance_support_user_id] = claims['user_id']
    else
      user = User.find_by!(tenant: tenant, email: claims.fetch('email'), active: true, role: 'admin')
      identity = user.google_login_identities.find_by!(email: user.email)
      identity.verify_subject!(claims.fetch('google_subject'))
      start_browser_session(user, method: 'google', google_email: user.email, google_identity: identity)
    end
    redirect_to inventory_index_path
  rescue RupertBilling::Error, ActiveRecord::RecordNotFound, GoogleOauthService::ExchangeError, KeyError
    render plain: 'Workspace sign-in could not be verified. Return to the control plane and try again.', status: :forbidden
  end
end
