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
    assert_select 'header img', count: 1
    assert_select 'header a.app-brand[aria-label="Rupert start page"] img[alt=""][width="32"][height="32"]', count: 1
    assert_select 'header .account-menu', text: /Store administrator/
  end

  test 'the rail lists the current section pages in groups with the current page marked' do
    get inventory_index_path
    assert_select 'aside#app-rail nav[aria-label="Module"]', count: 1
    assert_select 'nav[aria-label="Module"] .rail-group', text: 'Counts & requests'
    assert_select 'nav[aria-label="Module"] a[aria-current="page"]', text: 'Inventory'
    assert_select 'nav[aria-label="Module"] a', text: 'Locations'
    assert_select 'aside#app-rail button[data-rail-target="collapse"]', count: 1
    assert_select 'header button[data-rail-target="menu"][aria-controls="app-rail"]', count: 1
  end

  test 'every page carries the status bar with sync, the Team chat badge and the build' do
    get inventory_index_path
    assert_select 'footer.app-statusbar', count: 1
    assert_select 'footer.app-statusbar a[href=?]', syncs_path
    assert_select 'footer.app-statusbar a[href=?] .badge[data-team-chat-badge-target="count"][hidden]', team_chat_path
    assert_select 'header a[aria-label="Team chat"][data-chat-dock-target="trigger"] .chat-dock-badge[data-chat-dock-target="badge"]', count: 1
    assert_select '.app-shell[data-controller~="chat-dock"][data-chat-dock-unread-url-value=?]', team_chat_unread_path
    assert_select '.app-shell[data-controller~="team-chat-badge"][data-team-chat-badge-url-value=?]', team_chat_messages_path('general')
    assert_select '.toast-stack[data-controller="toasts"]', count: 1
    @admin.update!(role: 'cashier')
    get inventory_index_path
    assert_select 'footer.app-statusbar', count: 1
    assert_select 'footer.app-statusbar a[href=?]', team_chat_path, count: 0
    assert_select '.app-shell[data-controller~="team-chat-badge"]', count: 0
    assert_select '.app-shell[data-controller~="chat-dock"]', count: 0
  end

  test 'cashier sees work areas and personal help without administrative utility or sync metadata' do
    @admin.update!(role: 'cashier')
    SyncRun.create!(tenant_id: @tenant.id, source: 'swipesimple', mode: 'csv', status: 'success',
      startedAt: 2.minutes.ago, finishedAt: 1.minute.ago)
    get inventory_index_path
    assert_response :success
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Team"]', count: 0
    assert_select 'nav[aria-label="Module areas"] a[aria-label="System"]', count: 0
    assert_select 'a[aria-label="Instance overview"]', count: 0
    assert_select '#statusbar-sync a', count: 0
    refute_includes response.body, 'swipesimple · csv'
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Me"]'
    assert_select '.account-menu a[href=?]', time_clock_path, count: 0
    assert_select '.account-menu a[href=?]', roadmap_path
    assert_select '.account-menu', text: /Cashier/
  end

  test 'account menu repeats nothing the area tabs already offer' do
    get inventory_index_path
    assert_response :success
    assert_select '.account-menu a[href=?]', people_timesheets_path, count: 0
    assert_select '.account-menu a[href=?]', learning_index_path, count: 0
    assert_select '.account-menu a[href=?]', employee_app_path
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Team"]'
    assert_select '.account-menu a[href=?]', time_clock_path, count: 0
    assert_select 'nav[aria-label="Module areas"] a[aria-label="System"]'
    assert_select '.account-menu a[href=?]', roadmap_path, count: 0
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
    assert_select 'a[aria-label="Instance overview"]', count: 0
    assert_select 'nav[aria-label="Module"] a[href=?]', system_path, count: 0
    @admin.update!(role: 'super_admin')
    get platform_path
    assert_response :success
    assert_select 'a[aria-label="Instance overview"] svg'
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
