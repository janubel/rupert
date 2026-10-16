# frozen_string_literal: true

# Opt-in local intake. A trusted operator/export producer supplies CSV files and
# manifests; this worker never logs into SwipeSimple or handles vendor passwords.
class SwipesimpleInboxJob < ApplicationJob
  queue_as :default

  def perform(tenant_id: nil)
    previous_tenant = Current.tenant
    directory = ENV['RUPERT_SWIPESIMPLE_INBOX'].presence
    return { status: 'disabled', imported: 0 } unless directory

    raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox must be an absolute directory.' unless Pathname.new(directory).absolute? && File.directory?(directory) && !File.symlink?(directory)

    imported = 0
    File.open(File.join(directory, '.intake.lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      return { status: 'busy', imported: 0 } unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      manifests = Dir.glob(File.join(directory, '*.ready.json')).sort
      raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox exceeds 100 pending files.' if manifests.length > 100

      manifests.each do |path|
        manifest = JSON.parse(read_regular_file(path, 16 * 1024))
        raise SwipesimpleReportImporter::Error, 'Invalid SwipeSimple inbox manifest.' unless manifest.is_a?(Hash)
        next if tenant_id && manifest['tenant_id'] != tenant_id

        tenant = Tenant.find_by(id: manifest['tenant_id'], status: 'active')
        raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox workspace is unavailable.' unless tenant
        Current.tenant = tenant
        filename = manifest['csv'].to_s
        unless filename.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\.csv\z/)
          raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox CSV must be a plain basename.'
        end
        csv = read_regular_file(File.join(directory, filename), SwipesimpleReportImporter::MAX_BYTES)
        unless manifest['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.hexdigest(csv.b) == manifest['sha256']
          raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox document digest differs from its manifest.'
        end
        prepared = SwipesimpleReportImporter.preview(csv, manifest)
        SwipesimpleReportImporter.import!(csv, manifest, expected_fingerprint: prepared.fingerprint)
        # CSV remains available locally; encrypted exact bytes are also retained
        # in the receipt. A crash before rename safely replays next hour.
        File.rename(path, path.delete_suffix('.ready.json') + '.imported.json')
        imported += 1
      end
    end
    { status: 'complete', imported: imported }
  rescue StandardError
    # Do not serialize filenames, manifest contents, CSV values or system errors
    # into ActiveJob/Solid Queue failure logs.
    raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox intake failed. Review pending files privately; committed receipts remain replay-safe.', cause: nil
  ensure
    Current.tenant = previous_tenant if defined?(previous_tenant)
  end

  private

  def read_regular_file(path, limit)
    File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
      raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox requires bounded regular files.' unless file.stat.file? && file.stat.size <= limit
      text = file.read(limit + 1)
      raise SwipesimpleReportImporter::Error, 'SwipeSimple inbox file is too large.' if text.bytesize > limit
      text
    end
  end
end
