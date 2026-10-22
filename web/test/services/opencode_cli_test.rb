# frozen_string_literal: true

require 'test_helper'

class OpencodeCliTest < ActiveSupport::TestCase
  test 'run_command uses only flags opencode 2.0.32 accepts' do
    command = OpencodeCli.run_command(binary: 'opencode', agent: 'chat', prompt: 'hello')
    assert_equal ['opencode', 'run', '--standalone', '--format', 'json', '--agent', 'chat', 'hello'], command
    refute_includes command, '--pure'
    refute_includes command, '--dir'
  end

  test 'popen options run in a scratch directory with stdin closed' do
    options = OpencodeCli.popen_options
    assert_equal OpencodeCli::WORKDIR, options[:chdir]
    assert File.directory?(OpencodeCli::WORKDIR)
    assert_equal File::NULL, options[:in]
  end

  test 'env keeps opencode config, credentials and state out of the checkout' do
    Dir.mktmpdir do |dir|
      ENV['OPENCODE_STATE_DIR'] = dir
      env = OpencodeCli.env
      %w[XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME].each do |key|
        assert env[key].start_with?(dir), key
        assert File.directory?(env[key]), key
        assert_not env[key].start_with?(Rails.root.parent.to_s), key
      end
      assert env['OPENCODE_CONFIG'].end_with?('deploy/ser8/ask-rupert/opencode.json')
    ensure
      ENV.delete('OPENCODE_STATE_DIR')
    end
  end

  test 'without a writable state dir env falls back to scratch, never the checkout' do
    ENV['OPENCODE_STATE_DIR'] = '/nonexistent/rupert-opencode'
    assert OpencodeCli.env['XDG_DATA_HOME'].start_with?(OpencodeCli::WORKDIR)
  ensure
    ENV.delete('OPENCODE_STATE_DIR')
  end

  test 'the Ask Rupert opencode config denies every tool for the chat agent' do
    config = JSON.parse(Rails.root.join('../deploy/ser8/ask-rupert/opencode.json').read)
    assert_equal({ '*' => 'deny' }, config.dig('agent', 'chat', 'permission'))
  end
end
