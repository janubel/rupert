# frozen_string_literal: true

require 'fileutils'
require 'json'

# Rupert's side of the host auto-deployer (deploy/ser8/rupert-autodeploy.sh).
# The deployer runs as root outside the app and is the only thing that installs
# code; Rupert just reads what it reported and leaves it requests:
#   - status.json / last-deploy.json in STATE_DIR: written by the deployer.
#   - `manual` in the inbox: install only when asked (absent = automatic).
#   - `install-requested` in the inbox: install the newest green main now, or
#     retry a commit that failed. The deployer only reads its mtime.
# On a server without the deployer there is no status, and nothing here acts.
class AutoUpdate
  STALE_AFTER = 20.minutes

  Report = Struct.new(:state, :message, :current, :target, :mode, :install_requested, :at, keyword_init: true) do
    # An install that has gone quiet (the updater died mid-way) is not treated
    # as running, so the page offers Install again.
    def busy? = state == 'deploying' && !AutoUpdate.stale?(self)
    def failed? = state == 'failed'
  end

  class << self
    def state_dir = Pathname(ENV.fetch('RUPERT_AUTODEPLOY_STATE', '/var/lib/rupert-autodeploy'))
    def inbox = Pathname(ENV.fetch('RUPERT_AUTODEPLOY_INBOX', Rails.root.join('storage/autodeploy').to_s))

    # Updates change the code every workspace on this server runs, so only an
    # instance operator manages them.
    def manager?(user) = user.present? && user.super_admin? && user.can?('system.read')
    def operator?(user) = manager?(user) && user.can?('system.write')

    def status = read_report('status.json')
    def last_deploy = read_report('last-deploy.json')
    def installed? = status.present?

    def stale?(report = status, now: Time.current)
      report.nil? || report.at.nil? || report.at < now - STALE_AFTER
    end

    def manual? = inbox.join('manual').exist?

    def manual!(on)
      on ? write_inbox('manual', "Install updates only when asked\n") : FileUtils.rm_f(inbox.join('manual'))
    end

    def request_install!(actor:)
      write_inbox('install-requested', "#{Time.current.iso8601} user #{actor&.id}\n")
    end

    def cancel_request! = FileUtils.rm_f(inbox.join('install-requested'))

    def requested_at
      File.mtime(inbox.join('install-requested'))
    rescue Errno::ENOENT
      nil
    end

    # A request the deployer has not reported on yet. Whole seconds, like the
    # deployer (stat %Y, status times): the file's sub-second mtime would
    # otherwise look newer than a report written in the same second.
    def request_unseen?(report = status)
      (at = requested_at).present? && (report&.at.nil? || at.to_i > report.at.to_i)
    end

    private

    def read_report(name)
      data = JSON.parse(state_dir.join(name).read)
      return unless data.is_a?(Hash)

      Report.new(state: data['state'].to_s, message: data['message'].to_s, current: data['current'].to_s,
        target: data['target'].to_s, mode: data['mode'].to_s, install_requested: data['install_requested'] == true,
        at: parse_time(data['at']))
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, JSON::ParserError
      nil
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def write_inbox(name, body)
      FileUtils.mkdir_p(inbox)
      path = inbox.join(name)
      File.write(path, body)
      path
    end
  end
end
