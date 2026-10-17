# frozen_string_literal: true

require 'test_helper'

class RoadmapFlowTest < ActionDispatch::IntegrationTest
  test 'signed out visitors cannot access the application catalog' do
    get roadmap_path
    assert_redirected_to login_path
  end

  test 'reader can inspect the roadmap without gaining operational permissions' do
    Current.tenant = tenants(:default_tenant)
    User.create!(email: 'roadmap-reader@example.com', password: 'password123', role: 'reader', tenant: Current.tenant)
    post login_path, params: { email: 'roadmap-reader@example.com', password: 'password123' }

    get roadmap_path
    assert_response :success
    assert_select 'h1', 'Features & roadmap'
    assert_select 'td', 'Planned'
    assert_select 'tr', text: /Chart of accounts and reporting/ do
      assert_select 'td', 'Available'
      assert_select 'td', /double-entry general ledger and financial statements/
    end
    assert_select 'tr', text: /Double-entry ledger and close/ do
      assert_select 'td', 'Available'
      assert_select 'td', /ledger period locks that block edits to closed periods/
    end
    assert_select 'tr', text: /Bank reconciliation and accounting exports/ do
      assert_select 'td', 'Partial'
      assert_select 'td', /Automated duplicate review remains/
    end

    get system_path
    assert_redirected_to root_path
  ensure
    Current.reset
  end
end
