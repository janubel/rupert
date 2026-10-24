# frozen_string_literal: true

require 'test_helper'

class DirectorySyncTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @origin = 'https://fixture.api.cannatrax.net'
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true, hourly_sync_enabled: true,
      credentials_json: { api_url: @origin, api_username: 'fixture', api_password: 'secret' }.to_json)
    stub_request(:post, "#{@origin}/api/auth/login").to_return(json(token: 'fixture-token',
      permissions: { accessible_stores: { '7' => 'Fixture' } }))
    %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN].each { |key| EnvStore.set(key, 'fixture') }
  end

  teardown { Current.reset }

  def json(value)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: value.to_json }
  end

  def customer(id, name = 'Fixture')
    { id: id, first_name: name, last_name: 'Person', email: 'fixture@example.com', phone_number: '555-0100',
      medical_id: 'MUST NOT SAVE', dob: 'PRIVATE', notes: 'PRIVATE' }
  end

  def page(rows, number: 1, last: 1, total: rows.size)
    json(data: rows, current_page: number, last_page: last, total: total)
  end

  def stub_customers(rows)
    stub_request(:get, "#{@origin}/api/v1/customers").with(query: { page: '1', per_page: '100' }).to_return(page(rows))
  end

  test 'complete customer pages import idempotently without medical fields or contact-based merges' do
    stub_request(:get, "#{@origin}/api/v1/customers").with(query: { page: '1', per_page: '100' })
      .to_return(page([customer(1)], number: 1, last: 2, total: 2))
    stub_request(:get, "#{@origin}/api/v1/customers").with(query: { page: '2', per_page: '100' })
      .to_return(page([customer(2)], number: 2, last: 2, total: 2))
    2.times { assert_equal 2, Directories::Sync.call(provider: 'ctrax', kind: 'customers') }
    rows = Core::Customer.where(source: 'ctrax')
    assert_equal 2, rows.count
    assert rows.all?(&:source_synced_at)
    assert_equal ['fixture.api.cannatrax.net/1', 'fixture.api.cannatrax.net/2'], rows.order(:external_id).pluck(:external_id)
    refute_includes rows.map(&:attributes).to_json, 'PRIVATE'
    assert_equal 'success', DirectorySyncState.find_by!(provider: 'ctrax', kind: 'customers').status
    assert_not_requested :post, %r{/api/v1/}
  end

  test 'customers with no name or contact details are skipped' do
    blank = { id: 3, first_name: nil, last_name: '', email: nil, phone_number: ' ' }
    stub_customers([customer(1), blank])
    Directories::Sync.call(provider: 'ctrax', kind: 'customers')
    assert_equal ['fixture.api.cannatrax.net/1'], Core::Customer.where(source: 'ctrax').pluck(:external_id)
  end

  test 'failure on a later page retains the complete last successful directory' do
    stub_customers([customer(1, 'Original')])
    Directories::Sync.call(provider: 'ctrax', kind: 'customers')
    before = Core::Customer.where(source: 'ctrax').map(&:attributes)
    stub_request(:get, "#{@origin}/api/v1/customers").with(query: { page: '1', per_page: '100' })
      .to_return(page([customer(1, 'Changed')], last: 2, total: 2))
    stub_request(:get, "#{@origin}/api/v1/customers").with(query: { page: '2', per_page: '100' })
      .to_return(status: 403, body: 'PRIVATE upstream denial')
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'ctrax', kind: 'customers') }
    assert_equal before, Core::Customer.where(source: 'ctrax').map(&:attributes)
    state = DirectorySyncState.find_by!(provider: 'ctrax', kind: 'customers')
    assert_equal 'failed', state.status
    assert_equal 1, state.record_count
    assert state.last_success_at
    refute_includes state.error, 'PRIVATE'
  end

  test 'employee imports do not create logins pay rates or invent employment terms' do
    stub_request(:get, "#{@origin}/api/v1/users").with(query: { store_id: '7', page: '1', per_page: '100' })
      .to_return(page([customer(9).except(:phone_number).merge(deleted_at: nil, is_superuser: false, password: 'PRIVATE')]))
    assert_no_difference ['User.count', 'People::PayRate.count'] do
      assert_equal 1, Directories::Sync.call(provider: 'ctrax', kind: 'employees')
    end
    employee = People::Employee.find_by!(source: 'ctrax')
    assert_nil employee.user_id
    assert_nil employee.hire_date
    assert_equal 'unspecified', employee.employment_type
    employee.update!(employment_type: 'part_time', phone: 'manually entered')
    employee.terminate!
    Directories::Sync.call(provider: 'ctrax', kind: 'employees')
    employee.reload
    assert employee.terminated?
    assert_equal 'part_time', employee.employment_type
    assert_equal 'manually entered', employee.phone
    stub_request(:get, "#{@origin}/api/v1/users").with(query: { store_id: '7', page: '1', per_page: '100' }).to_return(page([]))
    Directories::Sync.call(provider: 'ctrax', kind: 'employees')
    refute employee.reload.source_active
    assert employee.terminated?
  end

  test 'invalid final employee rolls back the entire publication' do
    stub_request(:get, "#{@origin}/api/v1/users").with(query: { store_id: '7', page: '1', per_page: '100' })
      .to_return(page([customer(8), customer(9).merge(email: 'invalid')]))
    assert_no_difference 'People::Employee.count' do
      assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'ctrax', kind: 'employees') }
    end
  end

  test 'different tenants never share source identities or state' do
    stub_customers([customer(1)])
    Directories::Sync.call(provider: 'ctrax', kind: 'customers')
    other = Tenant.create!(name: 'Other', subdomain: 'directory-other')
    Current.tenant = other
    assert_empty Core::Customer.where(source: 'ctrax')
    assert_empty DirectorySyncState.all
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'ctrax', kind: 'customers') }
  end

  test 'changed credentials during a read prevent stale publication' do
    client = Object.new
    connection = @connection
    row = customer(1).stringify_keys
    client.define_singleton_method(:customers) do
      connection.update_columns(vendor_approved: false)
      [row]
    end
    Ctrax::Client.stubs(:new).returns(client)
    assert_no_difference 'Core::Customer.count' do
      assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'ctrax', kind: 'customers') }
    end
  end

  test 'Shopify uses full customer pagination and rejects repeated cursors before publishing' do
    node = { 'id' => 'gid://shopify/Customer/1', 'firstName' => 'Fixture', 'lastName' => nil,
      'defaultEmailAddress' => { 'emailAddress' => 'fixture@example.com' }, 'defaultPhoneNumber' => nil }
    ShopifyClient.expects(:graphql).with(Directories::ShopifyCustomers::QUERY, { cursor: nil })
      .returns({ 'customers' => { 'nodes' => [node], 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'NEXT' } } })
    ShopifyClient.expects(:graphql).with(Directories::ShopifyCustomers::QUERY, { cursor: 'NEXT' })
      .returns({ 'customers' => { 'nodes' => [node.merge('id' => 'gid://shopify/Customer/2')], 'pageInfo' => { 'hasNextPage' => false, 'endCursor' => 'END' } } })
    assert_equal 2, Directories::Sync.call(provider: 'shopify', kind: 'customers')
    assert_equal 2, Core::Customer.where(source: 'shopify').count
    ShopifyClient.stubs(:graphql).returns({ 'customers' => { 'nodes' => [node], 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'LOOP' } } },
      { 'customers' => { 'nodes' => [node.merge('id' => 'gid://shopify/Customer/3')], 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'LOOP' } } })
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'shopify', kind: 'customers') }
    assert_equal 2, Core::Customer.where(source: 'shopify').count
    existing = Core::Customer.find_by!(external_id: node['id'], source: 'shopify')
    CanonicalOrderImporter.send(:upsert_customer!, source: 'shopify', external_id: node['id'], email: nil, first_name: nil, last_name: nil)
    assert_equal 'Fixture', existing.reload.first_name
  end
  test 'native duplicate IDs and missing rows reject the entire customer response' do
    [page([customer(1), customer(1)]), page([customer(1)], total: 2), json(data: [customer(1)])].each do |document|
      stub_request(:get, "#{@origin}/api/v1/customers").with(query: { page: '1', per_page: '100' }).to_return(document)
      assert_no_difference 'Core::Customer.count' do
        assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'ctrax', kind: 'customers') }
      end
    end
  end
  test 'platform support superusers are excluded from the store employee roster' do
    stub_request(:get, "#{@origin}/api/v1/users").with(query: { store_id: '7', page: '1', per_page: '100' })
      .to_return(page([customer(1).merge(is_superuser: false), customer(2).merge(is_superuser: true)]))
    assert_equal 1, Directories::Sync.call(provider: 'ctrax', kind: 'employees')
    assert_equal ['fixture.api.cannatrax.net/1'], People::Employee.where(source: 'ctrax').pluck(:external_id)
  end
end
