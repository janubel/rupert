# frozen_string_literal: true

require 'test_helper'

class SystemBackupsTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Pathname(Dir.mktmpdir)
    @env = ENV['RUPERT_BACKUP_STATUS_DIR']
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @dir.to_s
    @user = users(:regular_user)
    @user.update!(role: 'super_admin')
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown do
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @env
    FileUtils.rm_rf(@dir)
    Current.reset
  end

  def write(layer, at:, state: 'ok', message: 'snapshot ok; 30 kept')
    @dir.join("#{layer}.json").write({ layer: layer, state: state, at: at.utc.iso8601, message: message, file: '/var/backups/x.gz', bytes: 41_000_000, kept: 30, free_bytes: 90_000_000_000 }.to_json)
  end

  test 'the system page shows every backup layer with its state and message' do
    write('frequent', at: 3.minutes.ago)
    write('local', at: 2.hours.ago)
    write('offhost', at: 20.hours.ago, state: 'failed', message: 'verification failed for rupert-20261021.sql.gz')
    get system_path
    assert_response :success
    assert_select '#backups[data-backups-summary=failed]'
    assert_select '[data-backup-layer=frequent][data-backup-state=ok]', text: /Rolling snapshot/
    assert_select '[data-backup-layer=local][data-backup-state=ok]'
    assert_select '[data-backup-layer=offhost][data-backup-state=failed]', text: /verification failed for rupert-20261021.sql.gz/
    assert_select '[data-backup-layer=offsite][data-backup-state=missing]', text: /Never reported on this server/
    assert_select '[data-backup-layer=verify][data-backup-state=missing]'
    assert_select '#backups', text: /A backup layer failed/
    assert_select '#backups', text: /39.1 MB/
  end

  test 'store admins do not see the system page at all' do
    @user.update!(role: 'admin')
    get system_path
    assert_redirected_to root_path
  end
end
