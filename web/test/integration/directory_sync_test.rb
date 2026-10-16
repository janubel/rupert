# frozen_string_literal: true

require 'test_helper'

class DirectorySyncIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
    Directories::Sync.stubs(:available?).with('ctrax').returns(true)
    Directories::Sync.stubs(:available?).with('shopify').returns(true)
  end

  teardown { Current.reset }

  test 'authorized directory buttons enqueue tenant-bound reads' do
    assert_enqueued_with(job: DirectorySyncJob, args: [@user.tenant_id, 'ctrax', 'employees', { manual: true }]) do
      post sync_directory_people_employees_path
    end
    assert_redirected_to people_employees_path
    assert_enqueued_with(job: DirectorySyncJob, args: [@user.tenant_id, 'shopify', 'customers', { manual: true }]) do
      post sync_directory_customers_path
    end
    get customers_path
    assert_response :success
    assert_select 'button', 'Sync customers now'
    get people_employees_path
    assert_response :success
    assert_select 'button', 'Sync employees now'
  end

  test 'readers cannot trigger directory jobs' do
    @user.update!(role: 'reader')
    assert_no_enqueued_jobs do
      post sync_directory_customers_path
      post sync_directory_people_employees_path
    end
  end
end
