# frozen_string_literal: true

require 'test_helper'

class ExpandedDirectorySyncTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'fixture')
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
  end

  teardown { Current.reset }

  def square_response(value)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: value.to_json }
  end

  test 'Square consumes all native customer pages and retains CRM annotations on refresh' do
    stub_request(:get, 'https://connect.squareup.com/v2/customers').with(query: { limit: '100', count: 'true', sort_field: 'CREATED_AT', sort_order: 'ASC' })
      .to_return(square_response(customers: [{ id: 'square-1', given_name: 'Native' }], count: 2, cursor: 'NEXT'))
    stub_request(:get, 'https://connect.squareup.com/v2/customers').with(query: { limit: '100', count: 'true', sort_field: 'CREATED_AT', sort_order: 'ASC', cursor: 'NEXT' })
      .to_return(square_response(customers: [{ id: 'square-2', given_name: 'Second' }], count: 2))
    assert_equal 2, Directories::Sync.call(provider: 'square', kind: 'customers')
    customer = Core::Customer.find_by!(source: 'square', external_id: 'square-1')
    customer.update!(notes: 'Local', tags: 'vip', preferred_name: 'Display', crm_status: 'lead')
    assert_equal 2, Directories::Sync.call(provider: 'square', kind: 'customers')
    assert_equal ['Local', 'vip', 'Display', 'lead'], customer.reload.attributes.values_at('notes', 'tags', 'preferred_name', 'crm_status')
    assert_not_requested :post, %r{connect.squareup.com/v2/customers}
  end

  test 'Square wrong counts repeated cursors and late access failures cannot publish partial results' do
    stub_request(:get, 'https://connect.squareup.com/v2/customers').with(query: { limit: '100', count: 'true', sort_field: 'CREATED_AT', sort_order: 'ASC' })
      .to_return(square_response(customers: [{ id: 'square-1' }], count: 2, cursor: 'NEXT'))
    stub_request(:get, 'https://connect.squareup.com/v2/customers').with(query: { limit: '100', count: 'true', sort_field: 'CREATED_AT', sort_order: 'ASC', cursor: 'NEXT' })
      .to_return(square_response(customers: [{ id: 'square-2' }], count: 2, cursor: 'NEXT'))
    assert_no_difference 'Core::Customer.count' do
      assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'square', kind: 'customers') }
    end
    stub_request(:get, 'https://connect.squareup.com/v2/customers').with(query: { limit: '100', count: 'true', sort_field: 'CREATED_AT', sort_order: 'ASC', cursor: 'NEXT' }).to_return(status: 403, body: 'PRIVATE')
    assert_no_difference 'Core::Customer.count' do
      assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'square', kind: 'customers') }
    end
    refute_includes DirectorySyncState.last.error, 'PRIVATE'
  end

  test 'Square team reads active and inactive profiles without creating logins or pay records' do
    stub_request(:post, 'https://connect.squareup.com/v2/team-members/search').with(body: { limit: 200 }.to_json)
      .to_return(square_response(team_members: [{ id: 'team-1', status: 'ACTIVE', given_name: 'First', family_name: 'Person' }, { id: 'team-2', status: 'INACTIVE', given_name: 'Second', family_name: 'Person' }]))
    assert_no_difference ['User.count', 'People::PayRate.count'] do
      assert_equal 2, Directories::Sync.call(provider: 'square', kind: 'employees')
    end
    assert People::Employee.find_by!(source: 'square', external_id: 'team-1').source_active
    refute People::Employee.find_by!(source: 'square', external_id: 'team-2').source_active
  end

  test 'Shopify staff without entitlement is a visible failed read rather than an empty successful roster' do
    %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN].each { |key| EnvStore.set(key, 'fixture') }
    ShopifyClient.expects(:graphql).with(Directories::ShopifyStaff::ACCESS_QUERY).returns({ 'currentAppInstallation' => { 'accessScopes' => [{ 'handle' => 'read_customers' }] } })
    assert_no_difference 'People::Employee.count' do
      assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'shopify', kind: 'employees') }
    end
    assert_equal 'failed', DirectorySyncState.find_by!(provider: 'shopify', kind: 'employees').status
    assert_nil DirectorySyncState.last.last_success_at
  end

  test 'Shopify authorized staff imports preserve HR status and use native staff identities' do
    %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN].each { |key| EnvStore.set(key, 'fixture') }
    ShopifyClient.stubs(:graphql).with(Directories::ShopifyStaff::ACCESS_QUERY).returns({ 'currentAppInstallation' => { 'accessScopes' => [{ 'handle' => 'read_users' }] } })
    ShopifyClient.stubs(:graphql).with(Directories::ShopifyStaff::QUERY, { cursor: nil }).returns({ 'staffMembers' => { 'nodes' => [{ 'id' => 'gid://shopify/StaffMember/7', 'firstName' => 'Fixture', 'lastName' => 'Staff', 'active' => true }], 'pageInfo' => { 'hasNextPage' => false } } })
    assert_equal 1, Directories::Sync.call(provider: 'shopify', kind: 'employees')
    employee = People::Employee.find_by!(source: 'shopify')
    employee.terminate!
    Directories::Sync.call(provider: 'shopify', kind: 'employees')
    assert employee.reload.terminated?
    assert_nil employee.user_id
  end
end
