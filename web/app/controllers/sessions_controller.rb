# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login, only: %i[new create]

  def new
    redirect_to(Current.user.employee? ? employee_app_path : root_path) if Current.user
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
    if user&.active? && user.tenant&.status == 'active' && user.authenticate(params[:password])
      reset_session # prevent session fixation
      session[:user_id] = user.id
      session[:auth_method] = 'password'
      session[:employee_password_fingerprint] = Digest::SHA256.hexdigest(user.password_digest) if user.employee?
      AccessLogger.record(
        source: 'password',
        status: 'success',
        request: request,
        user: user,
        domain: user.email.to_s.split('@').last
      )
      redirect_to(user.employee? ? employee_app_path : root_path, notice: 'Signed in')
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
