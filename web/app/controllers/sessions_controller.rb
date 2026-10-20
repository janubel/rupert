# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login, only: %i[new create]

  def new
    redirect_to(sign_in_landing_path(Current.user)) if Current.user
  end

  def create
    email = params[:email].to_s.strip.downcase
    if LoginThrottle.blocked?(ip: request.remote_ip, email: email)
      minutes = LoginThrottle.lockout_minutes(ip: request.remote_ip, email: email)
      AccessLogger.record(
        source: 'password',
        status: 'failure',
        request: request,
        email: email,
        domain: email.split('@').last,
        detail: 'rate limited'
      )
      flash.now[:alert] = "Too many failed sign-in attempts. Try again in #{minutes} minute#{minutes == 1 ? '' : 's'}."
      return render(:new, status: :unprocessable_entity)
    end

    # Password accounts are tenant-scoped like Google sign-in: on a subdomain
    # the account must belong to that store's tenant, so tenant A's user cannot
    # sign in on tenant B's subdomain. On the root domain no tenant is
    # resolvable, so fall back to the unscoped email lookup.
    tenant = Current.tenant
    user = if tenant
      User.find_by(email: email, tenant_id: tenant.id)
    else
      User.find_by(email: email)
           end
    local_identity_allowed = !WorkspaceNode.isolated? || (user && !user.super_admin? && !user.email.end_with?('@support.invalid'))
    if local_identity_allowed && user&.active? && user.tenant&.status == 'active' && user.authenticate(params[:password])
      start_browser_session(user, method: 'password')
      AccessLogger.record(
        source: 'password',
        status: 'success',
        request: request,
        user: user,
        domain: user.email.to_s.split('@').last
      )
      redirect_to(sign_in_landing_path(user), notice: 'Signed in')
    else
      AccessLogger.record(
        source: 'password',
        status: 'failure',
        request: request,
        email: email,
        domain: email.split('@').last,
        detail: user ? 'invalid password' : 'unknown email'
      )
      flash.now[:alert] = 'Invalid email or password'
      render(:new, status: :unprocessable_entity)
    end
  end

  def destroy
    AccessLogger.record(source: 'logout', status: 'success', request: request, user: Current.user)
    session.delete(:user_id)
    Current.user = nil
    redirect_to(login_path, notice: 'Signed out')
  end
end
