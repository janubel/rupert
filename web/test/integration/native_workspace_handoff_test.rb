# frozen_string_literal: true

require 'test_helper'

# Opening an isolated workspace from the Rupert iPhone app: the control plane hands the one-time
# code to the app (rupert://workspace), which posts it to the instance itself.
class NativeWorkspaceHandoffTest < ActionDispatch::IntegrationTest
  NATIVE_UA = { 'User-Agent' => 'Mozilla/5.0 (iPhone) Rupert iOS/1.0.0; Hotwire Native iOS; Turbo Native iOS' }.freeze

  setup do
    @keys = %w[RUPERT_PROVISION_WORKSPACES RUPERT_WORKSPACE_BASE_DOMAIN RUPERT_PROVISIONER_TOKEN]
    @saved = ENV.to_h.slice(*@keys)
    ENV.update('RUPERT_PROVISION_WORKSPACES' => 'true', 'RUPERT_WORKSPACE_BASE_DOMAIN' => 'workspaces.example.org',
      'RUPERT_PROVISIONER_TOKEN' => 'private-worker-test-token-0123456789')
    @tenant = Tenant.create!(name: 'Native Isolated', subdomain: 'native-isolated')
    @owner = User.create!(tenant: @tenant, email: 'native.isolated@gmail.com', name: 'Owner', role: 'admin', password: 'password123')
    @owner.google_login_identities.create!(email: @owner.email, google_subject: 'native-isolated-owner')
    @deployment = WorkspaceDeployment.request!(tenant: @tenant, owner: @owner)
    @deployment.update!(status: 'ready')
  end

  teardown do
    @keys.each { |key| @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key) }
    Current.reset
  end

  test 'the app gets the handoff as a rupert://workspace link, the browser keeps the form' do
    post login_path, params: { email: @owner.email, password: 'password123' }
    post workspace_session_path, headers: NATIVE_UA
    uri = URI.parse(response.location)
    assert_equal %w[rupert workspace], [uri.scheme, uri.host]
    query = Rack::Utils.parse_query(uri.query)
    assert_equal @deployment.origin, query['origin']
    assert_equal 'http://www.example.com', query['control']
    claims = WorkspaceHandoff.consume!(deployment: @deployment, secret: query['handoff'])
    assert_equal @owner.email, claims['email']

    post workspace_session_path
    assert_response :success
    assert_select 'form[method=post][action=?]', @deployment.origin + '/instance/session'
  end

  test 'the workspace button skips Turbo so the handoff page or app link is followed' do
    post login_path, params: { email: @owner.email, password: 'password123' }
    get workspace_path
    assert_select 'form[action=?][data-turbo=false]', workspace_session_path
  end
end
