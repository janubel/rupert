# frozen_string_literal: true

require 'test_helper'

class AutoUpdateTest < ActiveSupport::TestCase
  setup do
    @dir = Pathname(Dir.mktmpdir)
    @env = ENV.to_h.slice('RUPERT_AUTODEPLOY_STATE', 'RUPERT_AUTODEPLOY_INBOX')
    ENV['RUPERT_AUTODEPLOY_STATE'] = @dir.join('state').to_s
    ENV['RUPERT_AUTODEPLOY_INBOX'] = @dir.join('inbox').to_s
  end

  teardown do
    %w[RUPERT_AUTODEPLOY_STATE RUPERT_AUTODEPLOY_INBOX].each { |key| ENV[key] = @env[key] }
    FileUtils.rm_rf(@dir)
  end

  def write_status(name = 'status.json', **fields)
    @dir.join('state').mkpath
    @dir.join('state', name).write({ state: 'up_to_date', message: 'up to date', current: 'a' * 40, target: 'a' * 40,
                                     mode: 'automatic', install_requested: false, at: Time.current.utc.iso8601 }.merge(fields).to_json)
  end

  test 'a server without the deployer reports nothing' do
    assert_nil AutoUpdate.status
    assert_nil AutoUpdate.last_deploy
    assert_not AutoUpdate.installed?
    assert AutoUpdate.stale?
  end

  test 'reads what the deployer reported' do
    write_status(state: 'failed', message: 'abc failed', install_requested: true)
    write_status('last-deploy.json', state: 'failed', target: 'b' * 40)
    status = AutoUpdate.status
    assert AutoUpdate.installed?
    assert status.failed?
    assert status.install_requested
    assert_equal 'abc failed', status.message
    assert_not AutoUpdate.stale?
    assert_equal 'b' * 40, AutoUpdate.last_deploy.target
  end

  test 'old or unreadable reports do not count as a live updater' do
    write_status(at: 3.hours.ago.utc.iso8601)
    assert AutoUpdate.stale?
    @dir.join('state', 'status.json').write('{not json')
    assert_nil AutoUpdate.status
    @dir.join('state', 'status.json').write('[]')
    assert_nil AutoUpdate.status
  end

  test 'manual mode and install requests are flag files in the inbox' do
    assert_not AutoUpdate.manual?
    AutoUpdate.manual!(true)
    assert AutoUpdate.manual?
    AutoUpdate.manual!(false)
    assert_not AutoUpdate.manual?

    assert_nil AutoUpdate.requested_at
    AutoUpdate.request_install!(actor: users(:regular_user))
    assert AutoUpdate.requested_at
    AutoUpdate.cancel_request!
    assert_nil AutoUpdate.requested_at
  end

  test 'a request is unseen until the deployer reports after it' do
    write_status(at: 1.minute.ago.utc.iso8601)
    AutoUpdate.request_install!(actor: nil)
    assert AutoUpdate.request_unseen?
    write_status(at: 1.minute.from_now.utc.iso8601)
    assert_not AutoUpdate.request_unseen?
  end

  test 'only instance operators manage updates' do
    user = users(:regular_user)
    assert_not AutoUpdate.manager?(user)
    user.role = 'super_admin'
    assert AutoUpdate.manager?(user)
    assert AutoUpdate.operator?(user)
    assert_not AutoUpdate.manager?(nil)
  end
end
