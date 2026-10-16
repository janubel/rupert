# frozen_string_literal: true

require 'test_helper'

class SwipesimpleDirectoryTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @connection = PosConnection.create!(provider: 'swipesimple', environment: 'production', account_reference: '42',
      vendor_approved: true, reporting_enabled: true, credentials_json: { web_email: 'reader@example.invalid', web_password: 'secret' }.to_json)
    Directories::SwipesimpleDirectory.any_instance.stubs(:login!)
    stub_request(:get, 'https://swipesimple.com/transactions').to_return(body: '<a href="/companies/42/dashboard">Company</a>')
    stub_request(:get, 'https://swipesimple.com/customers').to_return(body: '<table id="customers-list" data-source="/customers"></table>')
    stub_request(:get, 'https://swipesimple.com/companies/42/users').to_return(body: '<table id="users-list" data-source="/companies/42/users"></table>')
  end

  teardown { Current.reset }

  def response(rows, total: rows.size)
    { headers: { 'Content-Type' => 'application/json' }, body: { iTotalRecords: total, iTotalDisplayRecords: total, aaData: rows }.to_json }
  end

  def customer(id)
    { customer_number: "<a href=\"/customers/cus_#{id}\">#{id}</a>", name: 'Fixture Customer', email: 'fixture@example.com', phone: nil, card_on_file: 'PRIVATE' }
  end

  def stub_page(path, start, document)
    stub_request(:get, "https://swipesimple.com#{path}").with(query: { format: 'json', iDisplayStart: start.to_s, iDisplayLength: '100', sEcho: '1' }).to_return(document)
  end

  test 'native customer grid reads every row using company scoped IDs without payment card fields' do
    stub_page('/customers', 0, response([customer(1)], total: 2))
    stub_page('/customers', 1, response([customer(2)], total: 2))
    assert_equal 2, Directories::Sync.call(provider: 'swipesimple', kind: 'customers')
    assert_equal %w[42/cus_1 42/cus_2], Core::Customer.where(source: 'swipesimple').order(:external_id).pluck(:external_id)
    refute_includes Core::Customer.where(source: 'swipesimple').map(&:attributes).to_json, 'PRIVATE'
    assert_not_requested :post, %r{swipesimple.com/}
  end

  test 'native users are independent of transaction reports and do not receive automatic accounts' do
    stub_page('/companies/42/users', 0, response([{ link_to_user: '<a href="/companies/42/users/7/edit">fixture@example.com</a>', name: 'Fixture Employee', role: 'ADMIN' }]))
    assert_no_difference ['User.count', 'People::PayRate.count', 'SwipesimpleExport.count'] do
      assert_equal 1, Directories::Sync.call(provider: 'swipesimple', kind: 'employees')
    end
    employee = People::Employee.find_by!(source: 'swipesimple')
    assert_equal '42/7', employee.external_id
    assert_equal 'Fixture Employee', employee.name
    assert_nil employee.source_active
  end

  test 'missing late pages wrong company and duplicate IDs retain all prior records' do
    stub_page('/customers', 0, response([customer(1)]))
    Directories::Sync.call(provider: 'swipesimple', kind: 'customers')
    before = Core::Customer.where(source: 'swipesimple').map(&:attributes)
    stub_page('/customers', 0, response([customer(1)], total: 2))
    stub_page('/customers', 1, response([], total: 2))
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'swipesimple', kind: 'customers') }
    assert_equal before, Core::Customer.where(source: 'swipesimple').map(&:attributes)
    stub_page('/customers', 0, response([customer(1), customer(1)]))
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'swipesimple', kind: 'customers') }
    stub_request(:get, 'https://swipesimple.com/transactions').to_return(body: '<a href="/companies/43/dashboard">Wrong company</a>')
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'swipesimple', kind: 'customers') }
    assert_equal before, Core::Customer.where(source: 'swipesimple').map(&:attributes)
  end

  test 'verification errors pause automatic login attempts and credential changes prevent stale publication' do
    Directories::SwipesimpleDirectory.any_instance.stubs(:login!).raises(SwipesimpleWeb::Client::Error.new(:verification))
    assert_raises(Directories::Sync::Error) { Directories::Sync.call(provider: 'swipesimple', kind: 'customers') }
    refute @connection.reload.reporting_enabled
    assert_equal 'needs_login', @connection.last_report_status
  end
end
