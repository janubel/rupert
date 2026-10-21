# frozen_string_literal: true

module Uploads
  module Importers
    # The plug-in interface. A subclass sets its identity with the class macros and
    # implements:
    #
    #   detect(document)                  -> Detection, [Detection] or nil
    #   preview(document)                 -> optional richer preview (default is generic)
    #   dry_run(document, params, upload) -> Outcome, with no lasting writes
    #   import!(document, params, upload, actor:) -> Outcome (the only step that writes)
    #
    # The workflow runs dry_run inside a transaction it always rolls back, and it
    # only calls import! after a successful dry run of the same file and
    # parameters has been approved by a person who holds `permission`.
    class Base
      class << self
        attr_reader :key, :label, :source, :permission, :formats, :version, :error_classes

        def importer(key, label:, source:, permission:, formats: %w[csv], version: 1, errors: [ArgumentError])
          @key = key
          @label = label
          @source = source
          @permission = permission
          @formats = formats
          @version = version
          @error_classes = errors
        end

        # False until whatever this importer depends on is installed.
        def available? = true

        # Fields the operator must supply before a dry run, for example an account
        # name. Each is { name:, label:, hint:, type: (:text | :boolean | :select), required:, options: }.
        def params_spec(_document = nil, _detection = nil) = []

        # Where the imported records can be seen afterwards (a path string).
        def destination_label = nil
      end

      def detect(_document)
        raise NotImplementedError
      end

      def suggested_params(_document, _detection) = {}

      def preview(_document) = nil

      def dry_run(_document, _params, _upload)
        raise NotImplementedError
      end

      def import!(_document, _params, _upload, actor:)
        raise NotImplementedError
      end

      private

      def detection(type, label, confidence, reason, source: self.class.source)
        Detection.new(type: type, label: label, confidence: confidence.round(2), reason: reason, importer: self.class.key, source: source)
      end

      def outcome(headline, counts: {}, warnings: [], path: nil)
        Outcome.new(ok: true, summary: { 'headline' => headline, 'counts' => counts, 'warnings' => warnings }, path: path)
      end

      def helpers = Rails.application.routes.url_helpers

      # Importers parse the text the document decoded (UTF-8, no BOM).
      def text!(document)
        document.text or raise ArgumentError, 'The file is not readable text.'
      end
    end
  end
end
