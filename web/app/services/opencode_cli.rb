# frozen_string_literal: true

require 'fileutils'

# How Rupert runs `opencode run` for a one-shot, text-only reply (Ask Rupert and team chat's fallback engine, inside the
# rupert container). SER8 pins opencode 2.0.32 there: that release has no `--pure` or
# `--dir` (it rejects them as "Unrecognized flag"), runs a private server only with `--standalone` (otherwise it talks to
# a background service), and works in the process's current directory.
#
# Its config and credentials must NOT live in the app checkout (a dirty checkout blocks auto-deploy, and a credential
# must never be committed or backed up with the code). They live in OPENCODE_STATE_DIR, default /var/lib/rupert-opencode,
# which an operator creates once and logs in to; without it opencode falls back to a scratch directory and has no
# credential. The `chat` agent (all tools denied) comes from deploy/ser8/ask-rupert/opencode.json in the checkout,
# or from OPENCODE_CONFIG.
module OpencodeCli
  WORKDIR = '/tmp/opencode'
  DEFAULT_STATE_DIR = '/var/lib/rupert-opencode'

  def self.run_command(binary:, agent:, prompt:)
    [binary, 'run', '--standalone', '--format', 'json', '--agent', agent, prompt]
  end

  def self.state_dir
    dir = ENV['OPENCODE_STATE_DIR'].presence || DEFAULT_STATE_DIR
    File.directory?(dir) && File.writable?(dir) ? dir : File.join(WORKDIR, 'state')
  end

  def self.config_path
    ENV['OPENCODE_CONFIG'].presence || Rails.root.join('../deploy/ser8/ask-rupert/opencode.json').to_s
  end

  # Environment for IO.popen: opencode's config, data, cache and state directories all outside the checkout.
  def self.env
    base = state_dir
    dirs = %w[config data cache state].to_h { |name| ["XDG_#{name.upcase}_HOME", File.join(base, name)] }
    dirs.each_value { |dir| FileUtils.mkdir_p(dir) }
    dirs.merge('OPENCODE_CONFIG' => config_path)
  end

  # Options for IO.popen: a scratch directory, errors merged into the output, and no stdin (opencode 2.x waits on an
  # open stdin instead of exiting when the run is done).
  def self.popen_options
    FileUtils.mkdir_p(WORKDIR)
    { chdir: WORKDIR, err: %i[child out], in: File::NULL }
  end
end
