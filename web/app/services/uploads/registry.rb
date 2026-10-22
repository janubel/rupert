# frozen_string_literal: true

require 'digest'

module Uploads
  # The list of importers the inbox can route to. An importer is a subclass of
  # Uploads::Importers::Base; add one to IMPORTERS (or call `register` from an
  # initializer or test) and it is offered detection, preview, dry run and import
  # with no change to the controllers. Order breaks confidence ties.
  module Registry
    IMPORTERS = %w[
      Uploads::Importers::IrisDailyDeposits
      Uploads::Importers::AuthorizeNetPortal
      Uploads::Importers::SwipesimpleReport
      Uploads::Importers::Quickbooks
      Uploads::Importers::SwipesimpleSales
      Uploads::Importers::SwipesimpleItems
      Uploads::Importers::BankStatement
      Uploads::Importers::Recognized
    ].freeze

    @extra = []

    class << self
      def register(importer)
        @extra << importer unless @extra.include?(importer)
      end

      def reset_extra!
        @extra = []
      end

      def importers
        IMPORTERS.map(&:constantize) + @extra
      end

      def find(key)
        importers.find { |importer| importer.key == key.to_s }
      end

      # Every detection for the file, best first. An importer that raises while
      # sniffing is skipped: a broken sniffer must never block an upload.
      def detect(document)
        found = importers.flat_map do |importer|
          next [] unless importer.formats.include?(document.format)

          Array.wrap(importer.new.detect(document)).compact
        rescue StandardError => e
          Rails.error.report(e, handled: true, context: { uploads_importer: importer.key })
          []
        end
        found.each_with_index.sort_by { |detection, index| [-detection.confidence, index] }.map(&:first)
      end

      # Changes whenever an importer is added, removed or versioned, which is how
      # the inbox knows older "needs review" files deserve another look.
      def signature
        Digest::SHA256.hexdigest(importers.map { |importer| [importer.key, importer.version, importer.available?] }.to_json).first(16)
      end
    end
  end
end
