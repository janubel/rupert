# frozen_string_literal: true

require 'test_helper'

class UpdatesPageTest < ActionDispatch::IntegrationTest
  CURRENT = 'a' * 40
  NEWER = 'b' * 40

  setup do
    @dir = Pathname(Dir.mktmpdir)
    @env = ENV.to_h.slice('RUPERT_AUTODEPLOY_STATE', 'RUPERT_AUTODEPLOY_INBOX')
    ENV['RUPERT_AUTODEPLOY_STATE'] = @dir.join('state').to_s
    ENV['RUPERT_AUTODEPLOY_INBOX'] = @dir.join('inbox').to_s
    BuildInfo.stubs(:current).returns(BuildInfo.new(revision: CURRENT))
    @user = users(:regular_user)
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown do
    %w[RUPERT_AUTODEPLOY_STATE RUPERT_AUTODEPLOY_INBOX].each { |key| ENV[key] = @env[key] }
    FileUtils.rm_rf(@dir)
    Current.reset
  end

  def write_status(name = 'status.json', **fields)
    @dir.join('state').mkpath
    @dir.join('state', name).write({ state: 'ready', message: 'bbbbbbbb is ready to install', current: CURRENT, target: NEWER,
                                     mode: 'manual', install_requested: false, at: Time.current.utc.iso8601 }.merge(fields).to_json)
  end

  def available
    UpdateChecker::Result.new(current: CURRENT, behind_by: 2, latest_message: 'Fix the thing',
      url: "https://github.com/techmore/rupert/compare/#{CURRENT}...main", checked_at: Time.current)
  end

  test 'store admins cannot see or drive updates even with the system permission' do
    assert @user.can?('system.write')
    get system_updates_path
    assert_redirected_to root_path
    post install_system_updates_path
    assert_redirected_to root_path
    patch system_updates_mode_path, params: { mode: 'manual' }
    assert_redirected_to root_path
    assert_nil AutoUpdate.requested_at
    assert_not AutoUpdate.manual?
  end

  test 'without the deployer the page explains that updates are managed outside Rupert' do
    @user.update!(role: 'super_admin')
    get system_updates_path
    assert_response :success
    assert_select 'h1', 'Updates'
    assert_select '[data-updater]', /not installed on this server/
    assert_select 'form[action=?]', install_system_updates_path, count: 0

    post install_system_updates_path
    assert_redirected_to system_updates_path
    assert_nil AutoUpdate.requested_at
  end

  test 'an operator sees the deployer status and can request an install' do
    @user.update!(role: 'super_admin')
    UpdateChecker.stubs(:enabled?).returns(true)
    UpdateChecker.stubs(:latest).returns(available)
    write_status
    write_status('last-deploy.json', state: 'deployed', message: 'deployed aaaaaaaa, healthy', current: 'c' * 40, target: CURRENT)
    AutoUpdate.manual!(true)

    get system_updates_path
    assert_response :success
    assert_select '[data-update-state=ready]', 'Ready to install'
    assert_select '[data-update-check]', /2 newer changes/
    assert_select '[data-last-deploy] [data-update-state=deployed]'
    assert_select 'input[name=mode][value=manual][checked]'
    assert_select 'form[action=?] button', install_system_updates_path, 'Install update now'

    assert_difference -> { ActivityLog.where(action: 'update_install_requested').count } do
      post install_system_updates_path
    end
    assert_redirected_to system_updates_path
    assert AutoUpdate.requested_at

    get system_updates_path
    assert_select '[data-update-request]', /picks it up within a few minutes/
    assert_select 'form[action=?]', install_system_updates_path, count: 1 # only the cancel form
    assert_select 'form[action=?] input[name=_method][value=delete]', cancel_system_updates_path

    delete cancel_system_updates_path
    assert_nil AutoUpdate.requested_at
  end

  test 'a failed update offers a retry' do
    @user.update!(role: 'super_admin')
    write_status(state: 'failed', message: 'bbbbbbbb failed (no new migrations); rolled back to aaaaaaaa')
    get system_updates_path
    assert_select '[data-update-state=failed]', 'Update failed'
    assert_select 'form[action=?] button', install_system_updates_path, 'Retry update'
  end

  test 'a silent updater is called out' do
    @user.update!(role: 'super_admin')
    write_status(state: 'up_to_date', at: 2.hours.ago.utc.iso8601)
    get system_updates_path
    assert_select '[data-updater-stale]', /rupert-autodeploy.timer/
  end

  test 'operators switch between automatic and manual installs' do
    @user.update!(role: 'super_admin')
    write_status
    patch system_updates_mode_path, params: { mode: 'manual' }
    assert_redirected_to system_updates_path
    assert AutoUpdate.manual?
    patch system_updates_mode_path, params: { mode: 'automatic' }
    assert_not AutoUpdate.manual?
    assert_equal %w[manual automatic], ActivityLog.where(action: 'update_mode_changed').order(:id).last(2).map(&:details)
  end

  test 'the banner sends operators to the updates page and says what will happen' do
    @user.update!(role: 'super_admin')
    UpdateChecker.stubs(:pending).returns(available)
    write_status(state: 'ready')
    get system_path
    assert_select '[data-update-banner]', /installs automatically once its checks pass/
    assert_select '[data-update-banner] a[href=?]', system_updates_path, 'Review and install'
  end

  test 'store admins keep the read-only banner' do
    UpdateChecker.stubs(:pending).returns(available)
    get root_path
    assert_select '[data-update-banner] a[href=?]', system_updates_path, count: 0
    assert_select '[data-update-banner] a', 'See what changed'
  end
end
