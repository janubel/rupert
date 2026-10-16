# frozen_string_literal: true

require 'test_helper'

class ErpPagesFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'erp@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'erp@example.com', password: 'password123' }

    @loc = Location.create!(source: 'square', externalId: 'loc1', name: 'Main Shop', tenant_id: @tenant.id)
    order = Core::Order.new(
      source: 'square',
      source_order_id: 'sq-1',
      channel: 'pos',
      gross_cents: 2500,
      line_items: 2,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      location_id: @loc.externalId
    )
    order.mark_paid!
    order.save!
  end

  def get_page(path)
    get path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' }
  end

  # CurrentAttributes reset after each request; re-establish for direct queries.
  def as_user
    Current.user = @user
    Current.tenant = @tenant
  end

  test 'sales page renders' do
    get_page sales_path
    assert_response :success
    assert_select 'h1', /Sales/
    assert_select 'td', /Main Shop/
  end

  test 'customers page renders' do
    get_page customers_path
    assert_response :success
    assert_select 'h1', /Customer CRM/
  end

  test 'projects page renders' do
    get_page projects_projects_path
    assert_response :success
    assert_select 'h1', /Projects/
  end

  test 'goals page renders' do
    get_page goals_goals_path
    assert_response :success
    assert_select 'h1', /Goals/
  end

  test 'kpis page renders' do
    get_page goals_kpis_path
    assert_response :success
    assert_select 'h1', /KPIs/
  end

  test 'pos sessions page renders' do
    get_page sales_pos_sessions_path
    assert_response :success
    assert_select 'h1', 'Rupert registers'
  end

  test 'create a project and transition it' do
    get_page new_projects_project_path
    assert_response :success

    post projects_projects_path, params: {
      project: { name: 'Spring Sale', description: 'Promo', due_on: '2026-09-01' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_select 'h1', /Spring Sale/

    as_user
    project = Projects::Project.find_by(name: 'Spring Sale')
    post transition_projects_project_path(project, event: 'start'),
      params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    assert_equal 'active', project.reload.status
  end

  test 'create a goal and update progress' do
    get_page new_goals_goal_path
    assert_response :success

    post goals_goals_path, params: {
      goal: { name: 'Monthly revenue', unit: 'USD', target_value: 25_000 },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_select 'h1', /Monthly revenue/

    as_user
    goal = Goals::Goal.find_by(name: 'Monthly revenue')
    patch goals_goal_path(goal), params: {
      goal: { current_value: 12_000 },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 12_000.0, goal.reload.current_value.to_f
  end

  test 'open and settle a register' do
    get_page new_sales_pos_session_path
    assert_response :success

    post sales_pos_sessions_path, params: {
      pos_session: { name: 'Front', location_id: @loc.externalId, opening_cash: '100.00' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_select 'h1', /Front/

    as_user
    session = Sales::PosSession.find_by(name: 'Front')
    assert session.open?
    post close_sales_pos_session_path(session), params: {
      counted_cents: 12_500,
      notes: 'all good',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert session.reload.closed?
    assert_equal 2500, session.variance_cents
  end
end
