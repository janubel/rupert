# frozen_string_literal: true

require 'fileutils'

module Uploads
  # Optional, OFF by default. A host-side drop directory for people or scripts that
  # can reach the server (for example over the tailnet with scp or rsync) but not
  # the web UI. Layout, with UPLOADS_DROP_DIR as the root:
  #
  #   <root>/<workspace subdomain>/incoming/     put files here
  #   <root>/<workspace subdomain>/processed/    kept-or-duplicate files are moved here
  #   <root>/<workspace subdomain>/quarantine/   refused files, renamed *.quarantined
  #
  # Every file goes through the same Intake as a browser upload, so size caps,
  # content checks, de-duplication and the audit line are identical. Only plain
  # files are read: symbolic links, hard-linked files, devices, sockets and
  # anything still being written are skipped, and a file is opened without
  # following links and checked again after opening.
  class DropScanner
    SETTLE_SECONDS = 10
    MAX_FILES_PER_RUN = 50
    SKIPPED_NAMES = /\A\.|\.(part|tmp|crdownload|filepart)\z|~\z/i

    Report = Struct.new(:taken, :duplicates, :quarantined, :skipped, :disabled_reason, keyword_init: true) do
      def initialize(**) = super(taken: 0, duplicates: 0, quarantined: 0, skipped: 0, **)
    end

    def self.enabled? = ENV['UPLOADS_DROP_ENABLED'] == '1' && ENV['UPLOADS_DROP_DIR'].to_s.start_with?('/')

    def self.call(root: ENV.fetch('UPLOADS_DROP_DIR', nil), now: Time.current)
      new(root, now).call
    end

    def initialize(root, now)
      @root = root.to_s
      @now = now
      @report = Report.new
    end

    def call
      return disabled('Disabled: set UPLOADS_DROP_ENABLED=1 and an absolute UPLOADS_DROP_DIR to enable.') unless @root.start_with?('/')
      return disabled('The drop root must be a real directory (not a symbolic link) that only its owner can write to.') unless safe_directory?(@root)

      Tenant.where(status: 'active').find_each do |tenant|
        base = File.join(@root, tenant.subdomain)
        next unless File.directory?(base) && safe_directory?(base)

        Current.set(tenant: tenant) { scan(base) }
      end
      @report
    end

    private

    def disabled(reason)
      @report.disabled_reason = reason
      @report
    end

    def safe_directory?(path)
      stat = File.lstat(path)
      stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o002).zero?
    rescue SystemCallError
      false
    end

    def scan(base)
      incoming = File.join(base, 'incoming')
      return unless File.directory?(incoming) && safe_directory?(incoming)

      names = Dir.children(incoming).sort.first(MAX_FILES_PER_RUN)
      names.each { |name| take(base, incoming, name) }
    end

    def take(base, incoming, name)
      path = File.join(incoming, name)
      stat = File.lstat(path)
      return skip unless stat.file? && !stat.symlink? && stat.nlink == 1 && name !~ SKIPPED_NAMES
      return skip if @now - stat.mtime < SETTLE_SECONDS

      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |io|
        opened = io.stat
        return skip unless opened.file? && opened.ino == stat.ino && opened.dev == stat.dev && opened.nlink == 1

        result = Intake.call(io, filename: name, origin: 'drop', actor: nil)
        finish(base, path, name, result.upload)
      end
    rescue SystemCallError => e
      Rails.logger.warn("[uploads] event=drop_skipped error=#{e.class.name.demodulize}")
      skip
    end

    def finish(base, path, name, upload)
      if upload.status == 'rejected'
        @report.quarantined += 1
        move(path, File.join(base, 'quarantine'), "#{upload.sha256.to_s.first(12).presence || SecureRandom.hex(6)}-#{Filename.clean(name)}.quarantined")
      else
        upload.status == 'duplicate' ? @report.duplicates += 1 : @report.taken += 1
        move(path, File.join(base, 'processed'), "#{upload.id}-#{Filename.clean(name)}")
      end
    end

    def move(path, directory, name)
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.rename(path, File.join(directory, name))
    rescue SystemCallError => e
      # Left in place: the next run sees an identical file and records a duplicate.
      Rails.logger.warn("[uploads] event=drop_move_failed error=#{e.class.name.demodulize}")
    end

    def skip
      @report.skipped += 1
      nil
    end
  end
end
