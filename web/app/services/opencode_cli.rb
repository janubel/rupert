# frozen_string_literal: true

require 'fileutils'

# How Rupert runs `opencode run` for a one-shot, text-only reply. SER8 pins
# opencode 2.0.32 (docs/ops/buzz-relay-ser8.md): that release has no `--pure`
# or `--dir` (it rejects them as "Unrecognized flag"), runs a private server
# only with `--standalone` (otherwise it talks to a background service), and
# works in the process's current directory.
module OpencodeCli
  WORKDIR = '/tmp/opencode'

  def self.run_command(binary:, agent:, prompt:)
    [binary, 'run', '--standalone', '--format', 'json', '--agent', agent, prompt]
  end

  # Options for IO.popen: a scratch directory, errors merged into the output, and no stdin (opencode 2.x waits on an
  # open stdin instead of exiting when the run is done).
  def self.popen_options
    FileUtils.mkdir_p(WORKDIR)
    { chdir: WORKDIR, err: %i[child out], in: File::NULL }
  end
end
