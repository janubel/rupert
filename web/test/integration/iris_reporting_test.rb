# frozen_string_literal: true

require 'test_helper'

class IrisReportingIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
    post login_path, params: { email: @owner.email, password: 'password' }
    @path = pos_connection_path('iris_reporting')
  end

  teardown { Current.reset }

  test 'setup has encrypted blank token inputs and saving never sends a vendor request or starts jobs' do
    get @path
    assert_response :success
    assert_includes response.body, 'Import a monthly Health Center summary'
    assert_no_enqueued_jobs do
      patch @path, params: { pos_connection: { environment: 'production', account_reference: '12345,67890', vendor_approved: true,
        credential_secret: { api_url: 'https://synthetic.iriscrm.com', api_token: 'synthetic-token' } } }
    end
    assert_response :redirect
    get @path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'input[type="password"][value]', count: 0
    refute_includes response.body, 'synthetic-token'
    assert_enqueued_with(job: IrisReportingJob) { post import_reporting_pos_connection_path('iris_reporting') }
    post disconnect_pos_connection_path('iris_reporting')
    assert_empty PosConnection.find_by!(provider: 'iris_reporting').credential_values
  end

  test 'invalid dates and unapproved credentials cannot queue a report' do
    assert_no_enqueued_jobs { post import_reporting_pos_connection_path('iris_reporting') }
    patch @path, params: { pos_connection: { environment: 'production', reporting_enabled: true } }
    assert_response :unprocessable_entity
    assert_no_enqueued_jobs { post import_reporting_pos_connection_path('iris_reporting'), params: { from: 'invalid' } }
  end

  test 'website setup saves encrypted credentials and queues only scoped native export jobs' do
    assert_no_enqueued_jobs do
      patch @path, params: { pos_connection: { reporting_auth_mode: 'web', environment: 'production', account_reference: '12345',
        vendor_approved: true, reporting_enabled: true, credential_secret: { web_username: 'synthetic-nab-user', web_password: 'synthetic-private-password' } } }
    end
    assert_redirected_to @path
    connection = PosConnection.find_by!(provider: 'iris_reporting')
    assert_equal 'web', connection.reporting_auth_mode
    assert_equal 'synthetic-nab-user', connection.credential_values['web_username']
    get @path
    assert_response :success
    assert_includes response.body, 'Pull Daily Deposits now'
    assert_includes response.body, 'NAB website username'
    assert_select 'input[type=password][value]', count: 0
    refute_includes response.body, 'synthetic-private-password'
    assert_enqueued_with(job: IrisDailyDepositsWebJob, args: [connection.id, { manual: true, setup_version: connection.lock_version }]) do
      post import_reporting_pos_connection_path('iris_reporting')
    end
    assert_enqueued_with(job: IrisDailyDepositsWebJob, args: [connection.id, { manual: true, setup_version: connection.lock_version }]) do
      post source_sync_path('bank')
    end
    assert_no_enqueued_jobs do
      patch @path, params: { pos_connection: { reporting_auth_mode: 'api_key', reporting_enabled: false } }
    end
    assert_empty connection.reload.credential_values
    assert_equal 'api_key', connection.reporting_auth_mode
  end

  test 'read permissions cannot save tokens or import CSV' do
    @owner.update_permission_overrides!(['settings.read'])
    get @path
    assert_response :success
    assert_select 'input[type="file"]', count: 0
    post import_iris_csv_pos_connection_path('iris_reporting')
    assert_response :redirect
    assert_equal 0, IrisReport.count
  end

  test 'CSV route rejects other providers and absent files' do
    post import_iris_csv_pos_connection_path('ctrax')
    assert_response :not_found
    post import_iris_csv_pos_connection_path('iris_reporting')
    assert_response :redirect
    assert_equal 0, IrisReport.count
  end

  test 'monthly file upload works without API credentials and records no duplicate snapshots' do
    Tempfile.create(['iris-synthetic', '.csv']) do |file|
      file.write("period,metric,value\n2026-10,gross_sales,10.00\n2026-10,returns,1.00\n2026-10,net_sales,9.00\n")
      file.flush
      2.times do
        upload = Rack::Test::UploadedFile.new(file.path, 'text/csv')
        post import_iris_csv_pos_connection_path('iris_reporting'), params: { merchant_number: '12345', report_kind: 'sales_health_csv', report_file: upload }
        assert_response :redirect
      end
    end
    assert_equal 1, IrisReport.count
    get @path
    assert_response :success
    assert_includes response.body, 'Sales health csv'
    assert_includes response.body, 'gross_sales'
  end

  test 'native daily deposits upload works without API access and rejects mismatched context without mutations' do
    get @path
    assert_select 'input[name=report_period][type=month][required]'
    assert_select 'button, input[type=submit]', value: 'Import Daily Deposits CSV'
    Tempfile.create(['iris-native-synthetic', '.csv']) do |file|
      file.write("Daily Deposits\nRecords exported: 1\n\nDate,Amount,Transactions,Batch,Terminal Number,Type\n10/1/2026,12.34,1,000001,,0\nMonthly Total,12.34,1,\n")
      file.flush
      params = { merchant_number: '12345', report_kind: 'daily_deposits_csv', report_period: '2026-10' }
      assert_no_difference ['Core::Order.unscoped.count', 'AuthorizeNetTransaction.unscoped.count'] do
        2.times do
          post import_iris_csv_pos_connection_path('iris_reporting'), params: params.merge(report_file: Rack::Test::UploadedFile.new(file.path, 'text/csv'))
          assert_redirected_to @path
        end
      end
      assert_equal 1, IrisReport.count
      assert_equal 'daily_deposits_csv', IrisReport.first.report_kind
      assert_nil PosConnection.find_by(provider: 'iris_reporting')
      post import_iris_csv_pos_connection_path('iris_reporting'), params: params.merge(report_period: '2026-09', report_file: Rack::Test::UploadedFile.new(file.path, 'text/csv'))
      follow_redirect!
      assert_includes response.body, 'matching report month'
      assert_equal 1, IrisReport.count
      @owner.update_permission_overrides!(['settings.read'])
      IrisReporting::DailyDepositsCsvImport.expects(:call).never
      post import_iris_csv_pos_connection_path('iris_reporting'), params: params.merge(report_file: Rack::Test::UploadedFile.new(file.path, 'text/csv'))
      assert_response :redirect
      assert_equal 1, IrisReport.count
    end
  end
end
