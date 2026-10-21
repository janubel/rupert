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
end
