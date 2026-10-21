# frozen_string_literal: true

require 'csv'
require 'digest'

module Uploads
  # The operator's steps on one upload: confirm or change the type, dry-run, approve,
  # discard, reopen and re-recognize. Three rules hold everywhere:
  #
  #  * a dry run runs inside a transaction that is ALWAYS rolled back, whatever the
  #    importer does, so it cannot change a record;
  #  * an import only runs for the exact file, importer and parameters a successful
  #    dry run covered (the digest), by someone allowed to write to the importer's
  #    destination, in one transaction with the status change;
  #  * every message returned to the person is plain words with no file contents.
  module Workflow
    Error = Class.new(StandardError)
    MAX_PARAM_LENGTH = 200

    class << self
      def digest_for(upload)
        importer = upload.importer
        Digest::SHA256.hexdigest([upload.sha256, upload.importer_key, upload.detected_type, upload.params.sort.to_h, importer&.version].to_json)
      end

      def allowed?(importer, user)
        user.can?('uploads.write') && (importer.permission == 'uploads.write' || user.can?(importer.permission))
      end

      # Importers that could be tried on this file, for the "choose another" list.
      def choices_for(upload)
        Registry.importers.select { |importer| importer.key != 'recognized' && importer.formats.include?(upload.file_format) }
      end

      def choose!(upload, importer_key:, type: nil, params: {}, actor:)
        ensure_open!(upload)
        importer = Registry.find(importer_key)
        raise Error, 'Choose one of the listed importers.' unless importer && importer.key != 'recognized' && importer.formats.include?(upload.file_format)
        raise Error, "#{importer.label} is not installed yet." unless importer.available?

        candidate = upload.candidates.find { |entry| entry['importer'] == importer.key && (type.blank? || entry['type'] == type) }
        detected_type = candidate ? candidate['type'] : importer.key
        document = Document.for(upload)
        upload.update!(importer_key: importer.key, detected_type: detected_type,
          detected_label: candidate ? candidate['label'] : importer.label, confidence: candidate && candidate['confidence'],
          detected_reason: candidate ? candidate['reason'] : "Chosen by #{name_of(actor)}.", operator_chosen: true, status: 'recognized', reason: nil,
          params_json: clean_params(importer, params, document, upload).to_json, dry_run_digest: nil, dry_run_at: nil,
          summary_json: drop_results(upload).to_json)
        Audit.record('type_confirmed', upload, actor: actor, detail: "importer=#{importer.key}")
        upload
      end

      def dry_run!(upload, actor:)
        importer = ready_importer!(upload, actor)
        missing = required_missing(importer, upload)
        raise Error, "Fill in: #{missing.to_sentence}." if missing.any?

        document = Document.for(upload)
        outcome = nil
        failure = nil
        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            outcome = importer.new.dry_run(document, upload.params, upload)
            raise ActiveRecord::Rollback
          end
        rescue *importer.error_classes, CSV::MalformedCSVError, ActiveRecord::RecordInvalid => e
          failure = friendly(e)
        rescue StandardError => e
          Rails.error.report(e, handled: true, context: { uploads_dry_run: upload.id })
          failure = 'The importer failed unexpectedly. Nothing was changed.'
        end
        save_dry_run(upload, outcome, failure, actor)
        Audit.record(failure ? 'dry_run_failed' : 'dry_run', upload, actor: actor)
        upload
      end

      def import!(upload, actor:)
        importer = ready_importer!(upload, actor)
        raise Error, 'Run a successful dry run first. An import only runs for the exact file and settings a dry run checked.' unless upload.dry_run_current?

        document = Document.for(upload)
        outcome = nil
        failure = nil
        begin
          Upload.transaction do
            Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
            upload.reload
            raise Error, 'This upload was already handled.' unless upload.open? && upload.dry_run_current?

            outcome = importer.new.import!(document, upload.params, upload, actor: actor)
            upload.update!(status: 'imported', imported_at: Time.current, imported_by_id: actor.id, imported_by_name: name_of(actor),
              result_path: outcome.path, reason: nil, summary_json: upload.summary.merge('import' => outcome.summary.merge('at' => Time.current.iso8601, 'by' => name_of(actor))).to_json)
          end
        rescue Error
          raise
        rescue *importer.error_classes, CSV::MalformedCSVError, ActiveRecord::RecordInvalid => e
          failure = friendly(e)
        rescue StandardError => e
          Rails.error.report(e, handled: true, context: { uploads_import: upload.id })
          failure = 'The import failed unexpectedly. Nothing was imported.'
        end
        if failure
          upload.reload.update!(reason: failure, dry_run_digest: nil, status: 'needs_review')
          Audit.record('import_failed', upload, actor: actor)
          raise Error, "Nothing was imported. #{failure}"
        end
        Audit.record('imported', upload, actor: actor, detail: "importer=#{importer.key}")
        upload
      end

      def discard!(upload, actor:)
        raise Error, 'Imported files cannot be discarded; reverse the import where it was made.' if upload.status == 'imported'
        raise Error, 'Only a kept file can be discarded.' unless upload.open?

        upload.update!(status: 'rejected', discarded_at: Time.current, discarded_by_name: name_of(actor),
          reason: "Discarded by #{name_of(actor)} on #{Time.current.strftime('%Y-%m-%d')}. The original is still kept.", dry_run_digest: nil)
        Audit.record('discarded', upload, actor: actor)
        upload
      end

      def reopen!(upload, actor:)
        raise Error, 'Only a discarded file can be reopened.' unless upload.discarded? && upload.status == 'rejected'

        upload.update!(status: 'received', discarded_at: nil, discarded_by_name: nil, reason: nil, operator_chosen: false, importer_key: nil)
        Recognizer.call(upload)
        Audit.record('reopened', upload, actor: actor)
        upload
      end

      def recognize!(upload, actor:)
        ensure_open!(upload)
        Recognizer.call(upload)
        Audit.record('recognized', upload, actor: actor)
        upload
      end

      # After a new importer ships: look again at everything still open.
      def recognize_all!(actor:)
        changed = 0
        Upload.open_items.where(retained: true).find_each do |upload|
          before = [upload.status, upload.importer_key, upload.detected_type]
          Recognizer.call(upload)
          changed += 1 unless before == [upload.status, upload.importer_key, upload.detected_type]
        end
        ActivityLogger.log('uploads_recognized_all', actor: actor, details: "#{changed} changed")
        Rails.logger.info("[uploads] event=recognize_all changed=#{changed}")
        changed
      end

      def clean_params(importer, raw, document = nil, upload = nil)
        raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        spec = importer.params_spec(document, upload && upload.candidates.find { |entry| entry['importer'] == importer.key }&.then { |entry| Detection.new(type: entry['type']) })
        spec.each_with_object({}) do |field, clean|
          value = raw[field[:name]] || raw[field[:name].to_sym]
          next if value.nil?

          text = value.to_s.gsub(/[[:cntrl:]]/, ' ').squish.first(MAX_PARAM_LENGTH)
          clean[field[:name]] = field[:type] == :boolean ? (text == '1' ? '1' : '0') : text
        end
      end

      private

      def ensure_open!(upload)
        raise Error, 'This file is not waiting for a decision.' unless upload.open? && upload.retained
      end

      def ready_importer!(upload, actor)
        ensure_open!(upload)
        importer = upload.importer or raise Error, 'Choose what kind of file this is first.'
        raise Error, "#{importer.label} is not installed yet." unless importer.available?
        raise Error, "You need permission to write to #{importer.destination_label || importer.label} (#{importer.permission}) to do this." unless allowed?(importer, actor)

        importer
      end

      def required_missing(importer, upload)
        importer.params_spec(nil, nil).select { |field| field[:required] && upload.params[field[:name]].blank? }.map { |field| field[:label] }
      end

      def save_dry_run(upload, outcome, failure, actor)
        results = drop_results(upload)
        if failure
          upload.update!(status: 'needs_review', reason: failure, dry_run_digest: nil, dry_run_at: Time.current, dry_run_by_name: name_of(actor),
            summary_json: results.merge('dry_run_error' => failure).to_json)
        else
          upload.update!(status: 'recognized', reason: nil, dry_run_digest: digest_for(upload), dry_run_at: Time.current, dry_run_by_name: name_of(actor),
            summary_json: results.merge('dry_run' => outcome.summary).to_json)
        end
      end

      def drop_results(upload) = upload.summary.except('dry_run', 'dry_run_error')

      def friendly(error)
        error.message.to_s.squish.first(500).presence || 'The importer could not read this file.'
      end

      def name_of(user) = user&.display_name || user&.email || 'system'
    end
  end
end
