# frozen_string_literal: true

require 'test_helper'

class CustomerManagementTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @customer = Core::Customer.create!(source: 'manual', external_id: 'crm-1', first_name: 'Fixture')
    @other = Tenant.create!(name: 'Other CRM', subdomain: 'other-crm')
    @foreign = Core::Customer.create!(tenant: @other, source: 'manual', external_id: 'crm-1', first_name: 'Foreign')
    @foreign_user = User.create!(tenant: @other, email: 'other-crm@example.com', password: 'password', role: 'admin')
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'manual customer form and redirects use the customer namespace and persist CRM fields' do
    get new_customer_path
    assert_response :success
    assert_select 'form[action=?]', customers_path
    assert_select 'input[name="customer[first_name]"]'
    assert_difference 'Core::Customer.count', 1 do
      post customers_path, params: { customer: { first_name: 'New contact', crm_status: 'lead', tags: 'retail, vip, retail', owner_id: @user.id } }
    end
    record = Core::Customer.order(:id).last
    assert_redirected_to customer_path(record)
    assert_equal 'retail, vip', record.tags
    get edit_customer_path(record)
    assert_response :success
    assert_select 'form[action=?]', customer_path(record)
  end

  test 'native contacts retain provenance while local relationship fields remain editable' do
    @customer.update!(source: 'square')
    patch customer_path(@customer), params: { customer: { first_name: 'Overwrite', source: 'manual', external_id: 'different', crm_status: 'vip', notes: 'Local summary' } }
    assert_redirected_to customer_path(@customer)
    assert_equal 'Fixture', @customer.reload.first_name
    assert_equal 'crm-1', @customer.external_id
    assert_equal 'vip', @customer.crm_status
    assert_equal 'Local summary', @customer.notes
  end

  test 'interactions follow-ups and completion are tenant bound with attributed authors' do
    assert_difference 'CustomerInteraction.count', 1 do
      post customer_interactions_path(@customer), params: { interaction: { kind: 'call', body: '<script>unsafe()</script>', author_id: @foreign_user.id, tenant_id: @other.id } }
    end
    assert_equal @user.id, CustomerInteraction.last.author_id
    assert_difference 'CustomerFollowUp.count', 1 do
      post customer_follow_ups_path(@customer), params: { follow_up: { title: 'Return call', due_on: Date.yesterday, owner_id: @user.id } }
    end
    follow_up = CustomerFollowUp.last
    get customers_path, params: { due: '1' }
    assert_response :success
    assert_select 'tbody a[href=?]', customer_path(@customer)
    assert_select 'tbody a[href=?]', customer_path(@foreign), count: 0
    patch customer_follow_up_path(@customer, follow_up), params: { event: 'complete' }
    assert follow_up.reload.completed_at
    patch customer_follow_up_path(@customer, follow_up), params: { event: 'reopen' }
    assert_nil follow_up.reload.completed_at
    get customer_path(@customer)
    assert_response :success
    assert_select 'script', text: 'unsafe()', count: 0
    assert_includes response.body, '&lt;script&gt;unsafe()&lt;/script&gt;'
  end

  test 'foreign owners customer IDs and nested follow-up IDs cannot cross workspaces' do
    patch customer_path(@customer), params: { customer: { owner_id: @foreign_user.id } }
    assert_response :unprocessable_entity
    assert_nil @customer.reload.owner_id
    assert_no_difference 'CustomerFollowUp.count' do
      post customer_follow_ups_path(@customer), params: { follow_up: { title: 'Bad', due_on: Date.current, owner_id: @foreign_user.id } }
    end
    assert_no_difference 'CustomerInteraction.count' do
      post customer_interactions_path(@foreign), params: { interaction: { body: 'Foreign' } }
    end
    assert_response :not_found
    sibling = Core::Customer.create!(source: 'manual', external_id: 'sibling')
    task = sibling.follow_ups.create!(title: 'Sibling', due_on: Date.current, author: @user)
    patch customer_follow_up_path(@customer, task), params: { event: 'complete' }
    assert_response :not_found
    assert_nil task.reload.completed_at
  end

  test 'readers can see CRM but cannot change annotations schedule tasks or bulk export contacts' do
    @user.update!(role: 'reader')
    get customer_path(@customer)
    assert_response :success
    assert_select 'textarea[name="interaction[body]"]', count: 0
    assert_no_difference ['CustomerInteraction.count', 'CustomerFollowUp.count'] do
      post customer_interactions_path(@customer), params: { interaction: { kind: 'note', body: 'Not allowed' } }
      post customer_follow_ups_path(@customer), params: { follow_up: { title: 'Not allowed', due_on: Date.current } }
    end
    get export_customers_path
    assert_redirected_to root_path
  end

  test 'CSV respects filters tenant scope and neutralizes spreadsheet formulas' do
    @customer.update!(first_name: '=HYPERLINK("unsafe")', crm_status: 'vip', tags: 'Fixture')
    get export_customers_path, params: { status: 'vip' }
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal 1, rows.size
    assert_equal "'=HYPERLINK(\"unsafe\")", rows.first['first_name']
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'CRM renders mixed currency totals separately and paginates full history' do
    %w[USD CAD].each_with_index do |currency, index|
      @customer.orders.create!(source: 'manual', source_order_id: "crm-order-#{index}", channel: 'manual', occurred_at: Time.current, gross_cents: 1000, currency: currency)
    end
    get customer_path(@customer)
    assert_response :success
    assert_includes response.body, 'CAD 10.00'
    assert_includes response.body, 'USD 10.00'
    26.times { |n| @customer.interactions.create!(author: @user, body: "Entry #{n}") }
    get customer_path(@customer), params: { activity_page: 2 }
    assert_response :success
    assert_select 'article', count: 1
  end
end
