# frozen_string_literal: true

# First-run setup: creates the super admin and the first tenant. Only reachable
# while no tenants exist. Subsequent tenants are added from the platform
# (TenantsController) by a super admin.
class SetupController < ApplicationController
  skip_before_action :require_login, only: %i[new create]

  def new
    return head :not_found if WorkspaceNode.isolated?
    redirect_to(login_path) if Tenant.exists?
  end

  def create
    return head :not_found if WorkspaceNode.isolated?
    return redirect_to(login_path) if Tenant.exists?

    tenant = Tenant.new(name: params[:tenant_name], subdomain: params[:tenant_subdomain])
    user = tenant.users.build(
      email: params[:user_email].to_s.downcase,
      name: params[:user_name],
      password: params[:user_password],
      role: 'super_admin'
    )

    if tenant.save
      seed_credentials(tenant)
      Current.tenant = tenant
      Finance::ChartOfAccounts.seed!
      Current.tenant = nil
      start_browser_session(user, method: 'password')
      redirect_to(root_url(subdomain: tenant.subdomain), notice: 'Welcome! Your workspace is ready.')
    else
      @tenant = tenant
      @user = user
      flash.now[:alert] = 'Please fix the errors below.'
      render(:new, status: :unprocessable_entity)
    end
  end

  private

  # Give the first tenant the credentials already present in .env so Herbal
  # Healers starts connected; other tenants configure their own keys.
  def seed_credentials(tenant)
    Current.tenant = tenant
    EnvStore::MANAGED_KEYS.each do |key|
      value = ENV[key]
      EnvStore.import!("#{key}=#{value}") if value.present?
    end
  ensure
    Current.tenant = nil
  end
end
