# frozen_string_literal: true

require 'test_helper'

class WorkspaceIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @keys = %w[RUPERT_PROVISION_WORKSPACES RUPERT_WORKSPACE_BASE_DOMAIN RUPERT_PROVISIONER_TOKEN RUPERT_NODE_MODE RUPERT_WORKSPACE_ID RUPERT_TENANT_ID RUPERT_INSTANCE_HOSTNAME RUPERT_INSTANCE_SECRET RUPERT_CONTROL_PLANE_ORIGIN]
    @saved = ENV.to_h.slice(*@keys)
    ENV.update('RUPERT_PROVISION_WORKSPACES' => 'true', 'RUPERT_WORKSPACE_BASE_DOMAIN' => 'workspaces.example.org', 'RUPERT_PROVISIONER_TOKEN' => 'private-worker-test-token-0123456789')
    @tenant = Tenant.create!(name: 'Isolated Customer', subdomain: 'isolated-customer')
    @owner = User.create!(tenant: @tenant, email: 'isolated.owner@gmail.com', name: 'Isolated Owner', role: 'admin', password: 'password123')
    @owner.google_login_identities.create!(email: @owner.email, google_subject: 'verified-isolated-owner')
    @deployment = WorkspaceDeployment.request!(tenant: @tenant, owner: @owner)
    @headers = { 'Authorization' => 'Bearer ' + ENV.fetch('RUPERT_PROVISIONER_TOKEN') }
  end
  teardown do
    @keys.each { |key| @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key) }
    Current.reset
  end

  test 'isolated signup queues a database deployment and does not seed business records on control plane' do
    before = Finance::Account.unscoped.count
    info = { 'email' => 'another.owner@gmail.com', 'sub' => 'new-isolated-subject', 'email_verified' => true }
    user = VerifiedWorkspaceRegistration.call(info: info, attributes: { 'workspace_name' => 'Another Shop', 'requested_subdomain' => 'another-shop' })
    assert_equal before, Finance::Account.unscoped.count
    assert WorkspaceDeployment.exists?(tenant: user.tenant, status: 'requested')
  end

  test 'control plane blocks customer business screens while provisioning and afterwards' do
    post login_path, params: { email: @owner.email, password: 'password123' }
    assert_redirected_to workspace_path
    get inventory_index_path
    assert_redirected_to workspace_path
    get workspace_path
    assert_response :success
    assert_includes response.body, 'preparing your separate workspace'
    @deployment.update!(status: 'ready')
    get inventory_index_path
    assert_redirected_to workspace_path
    get billing_path
    assert_response :success
  end

  test 'worker claims are authenticated exclusive encrypted and lease-bound' do
    post '/internal/workspaces/claim', as: :json
    assert_response :unauthorized
    post '/internal/workspaces/claim', headers: @headers, as: :json
    assert_response :success
    job = response.parsed_body
    assert_equal @deployment.instance_id, job['instance_id']
    assert_equal 'verified-isolated-owner', job['google_subject']
    assert_nil WorkspaceProvisioning.claim
    raw = WorkspaceDeployment.connection.select_value("SELECT instance_secret FROM workspace_deployments WHERE id = #{@deployment.id}")
    refute_includes raw, @deployment.instance_secret
    post "/internal/workspaces/#{@deployment.id}/progress", headers: @headers, params: { lease: 'wrong', phase: 'complete' }, as: :json
    assert_response :not_found
    post "/internal/workspaces/#{@deployment.id}/progress", headers: @headers, params: { lease: job['lease'], phase: 'complete' }, as: :json
    assert_response :success
    assert_equal 'ready', @deployment.reload.status
    assert_raises(ActiveRecord::RecordNotFound) { WorkspaceProvisioning.update!(id: @deployment.id, lease: job['lease'], phase: 'failed', failure_code: 'health_failed') }
  end

  test 'expired leases cannot mark an instance ready' do
    job = WorkspaceProvisioning.claim
    travel 31.minutes do
      assert_raises(ActiveRecord::RecordNotFound) { WorkspaceProvisioning.update!(id: @deployment.id, lease: job['lease'], phase: 'complete') }
    end
  end

  test 'handoff credentials are single-use short-lived and bound to exactly one instance' do
    @deployment.update!(status: 'ready')
    code = WorkspaceHandoff.issue!(deployment: @deployment, user: @owner)
    assert_not_equal code, WorkspaceHandoff.last.token_digest
    claims = WorkspaceHandoff.consume!(deployment: @deployment, secret: code)
    assert_equal @owner.email, claims['email']
    assert_equal @tenant.id, claims['tenant_id']
    assert_raises(ActiveRecord::RecordNotFound) { WorkspaceHandoff.consume!(deployment: @deployment, secret: code) }
    code = WorkspaceHandoff.issue!(deployment: @deployment, user: @owner)
    travel 3.minutes do
      assert_raises(ActiveRecord::RecordNotFound) { WorkspaceHandoff.consume!(deployment: @deployment, secret: code) }
    end
  end

  test 'only the exact instance secret can exchange a handoff and customer can submit it by POST' do
    @deployment.update!(status: 'ready')
    post login_path, params: { email: @owner.email, password: 'password123' }
    post workspace_session_path
    assert_response :success
    assert_select 'form[method=post][action=?]', @deployment.origin + '/instance/session'
    code = css_select('input[name=handoff]').first['value']
    endpoint = "/internal/workspaces/#{@deployment.instance_id}/exchange"
    post endpoint, headers: { 'Authorization' => 'Bearer wrong-instance-key' }, params: { code: code }, as: :json
    assert_response :unauthorized
    post endpoint, headers: { 'Authorization' => 'Bearer ' + @deployment.instance_secret }, params: { code: code }, as: :json
    assert_response :success
    assert_equal @owner.email, response.parsed_body['email']
  end

  test 'instance support access checks current customer grant and revokes immediately' do
    @deployment.update!(status: 'ready')
    operator = User.create!(tenant: tenants(:default_tenant), email: 'isolated-support@example.org', role: 'super_admin', password: 'password123')
    assert_raises(ActiveRecord::RecordNotFound) { WorkspaceHandoff.issue!(deployment: @deployment, user: operator) }
    grant = SupportAccessGrant.create!(tenant: @tenant, granted_by: @owner, support_user: operator, reason: 'Read only', expires_at: 1.hour.from_now)
    code = WorkspaceHandoff.issue!(deployment: @deployment, user: operator, grant: grant)
    grant.update_columns(revoked_at: Time.current)
    assert_raises(ActiveRecord::RecordNotFound) { WorkspaceHandoff.consume!(deployment: @deployment, secret: code) }
    endpoint = "/internal/workspaces/#{@deployment.instance_id}/support"
    post endpoint, headers: { 'Authorization' => 'Bearer ' + @deployment.instance_secret }, params: { grant_id: grant.id, user_id: operator.id }, as: :json
    assert_response :forbidden
  end

  test 'isolated node accepts exact host and blocks first-run administrator setup' do
    ENV.update('RUPERT_NODE_MODE' => 'workspace', 'RUPERT_TENANT_ID' => @tenant.id, 'RUPERT_WORKSPACE_ID' => @deployment.instance_id,
      'RUPERT_INSTANCE_HOSTNAME' => 'isolated.example.org', 'RUPERT_INSTANCE_SECRET' => @deployment.instance_secret,
      'RUPERT_CONTROL_PLANE_ORIGIN' => 'https://control.example.org')
    get root_path
    assert_response :misdirected_request
    host! 'isolated.example.org'
    get '/setup'
    assert_response :not_found
    get root_path
    assert_redirected_to login_path
    post '/instance/session', headers: { 'Origin' => 'https://attacker.example.org' }, params: { handoff: 'bad' }
    assert_response :forbidden
  end
  test 'customer instance allows its own password staff accounts but never a support identity password' do
    ENV.update('RUPERT_NODE_MODE' => 'workspace', 'RUPERT_TENANT_ID' => @tenant.id, 'RUPERT_WORKSPACE_ID' => @deployment.instance_id,
      'RUPERT_INSTANCE_HOSTNAME' => 'isolated.example.org', 'RUPERT_INSTANCE_SECRET' => @deployment.instance_secret,
      'RUPERT_CONTROL_PLANE_ORIGIN' => 'https://control.example.org')
    host! 'isolated.example.org'
    get login_path
    assert_response :success
    assert_includes response.body, 'Open with my Rupert account'
    post login_path, params: { email: @owner.email, password: 'password123' }
    assert_redirected_to root_path
    delete logout_path
    support = User.create!(tenant: @tenant, email: 'support-99@support.invalid', role: 'admin', password: 'password123')
    post login_path, params: { email: support.email, password: 'password123' }
    assert_response :unprocessable_entity
    assert_nil session[:user_id]
  end
end
