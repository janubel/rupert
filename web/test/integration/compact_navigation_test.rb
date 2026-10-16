# frozen_string_literal: true

require 'test_helper'

class CompactNavigationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'named areas and icon utilities expose accessible names and decorative vectors' do
    get inventory_index_path
    assert_response :success
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Stock"][aria-current="page"]'
    assert_select 'nav[aria-label="Module areas"] a svg[aria-hidden="true"][focusable="false"]'
    assert_select 'button.nav-utility[aria-label="Search"][title] svg'
    assert_select 'button[aria-haspopup="menu"][aria-label^="Account menu for "]'
    assert_select 'header img', count: 0
    assert_select 'header .account-menu', text: /Store administrator/
  end

  test 'stock tools use one disclosure with labelled links and current page' do
    get inventory_index_path
    assert_select 'nav[aria-label="Module"] details[data-controller="navigation-menu"]', count: 1
    assert_select 'nav[aria-label="Module"] summary[aria-label="Stock tools; current page Stock comparison"]'
    assert_select 'nav[aria-label="Module"] .module-menu-panel a[aria-current="page"]', text: 'Stock comparison'
    assert_select 'nav[aria-label="Module"] .module-menu-panel a', text: 'Locations'
    assert_select 'nav[aria-label="Module"] > a', count: 0
  end

  test 'cashier sees work areas and personal help without administrative utility or sync metadata' do
    @admin.update!(role: 'cashier')
    SyncRun.create!(tenant_id: @tenant.id, source: 'swipesimple', mode: 'csv', status: 'success',
      startedAt: 2.minutes.ago, finishedAt: 1.minute.ago)
    get inventory_index_path
    assert_response :success
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Team"]', count: 0
    assert_select 'nav[aria-label="Module areas"] a[aria-label="System"]', count: 0
    assert_select 'a.nav-utility[aria-label="Instance overview"]', count: 0
    assert_select '#header-sync-pill a', count: 0
    refute_includes response.body, 'swipesimple · csv'
    assert_select '.account-menu a[href=?]', time_clock_path
    assert_select '.account-menu a[href=?]', roadmap_path
    assert_select '.account-menu', text: /Cashier/
  end

  test 'delegated sales writer without inventory read has no POS shortcut' do
    @admin.update_permission_overrides!(%w[dashboard.read sales.read sales.write])
    get sales_path
    assert_response :success
    assert_select 'nav[aria-label="Module"] a[href=?]', point_of_sale_path, count: 0
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Stock"]', count: 0
  end

  test 'platform icons and system health require platform role even with delegated permissions' do
    @admin.update_permission_overrides!(%w[dashboard.read inventory.read system.read settings.read])
    get inventory_index_path
    assert_select 'a.nav-utility[aria-label="Instance overview"]', count: 0
    assert_select 'nav[aria-label="Module"] a[href=?]', system_path, count: 0
    @admin.update!(role: 'super_admin')
    get platform_path
    assert_response :success
    assert_select 'a.nav-utility[aria-label="Instance overview"] svg'
    assert_select 'nav[aria-label="Module"] a[href=?]', system_path
    assert_select '.account-menu', text: /Platform administrator/
  end

  test 'sizes navigation matches the backend settings read gate' do
    @admin.update_permission_overrides!(%w[dashboard.read inventory.read reconcile.read])
    get inventory_index_path
    assert_select 'nav[aria-label="Module"] a[href=?]', size_families_path, count: 0
    @admin.update_permission_overrides!(%w[dashboard.read inventory.read settings.read])
    get inventory_index_path
    assert_select 'nav[aria-label="Module"] a[href=?]', size_families_path
  end

  test 'revoked dashboard access removes search and makes the logo lead to an allowed module' do
    @admin.update_permission_overrides!(['inventory.read'])
    get inventory_index_path
    assert_response :success
    assert_select 'button[aria-label="Search"]', count: 0
    assert_select 'div[data-controller="search"]', count: 0
    assert_select 'a.app-brand[href=?]', inventory_index_path
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Overview"]', count: 0
  end
end
