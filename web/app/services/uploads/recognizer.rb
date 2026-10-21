# frozen_string_literal: true

module Uploads
  # Works out what a retained upload is and where it could go. It writes only the
  # inbox's own columns on the upload row. A file is called "recognized" only when
  # one importer is clearly ahead; anything else waits as "needs review" with the
  # reason, and is never guessed.
  module Recognizer
    AUTO_CONFIDENCE = 0.75
    MARGIN = 0.15
    FLOOR = 0.2

    def self.call(upload)
      return upload unless upload.retained && !upload.discarded?

      document = Document.for(upload)
      detections = Registry.detect(document).select { |detection| detection.confidence >= FLOOR }
      attrs = base_attributes(upload, document, detections)
      attrs.merge!(decide(upload, document, detections))
      upload.update!(attrs)
      upload
    end

    def self.base_attributes(upload, document, detections)
      { row_count: document.line_count || (document.format == 'xlsx' ? nil : upload.row_count),
        source_guess: SourceGuess.call(upload.filename, detections),
        candidates_json: detections.first(6).map(&:to_h).to_json,
        recognizer_version: Registry.signature, recognized_at: Time.current }
    end

    def self.decide(upload, document, detections)
      if upload.operator_chosen && (chosen = Registry.find(upload.importer_key)) && chosen.available?
        match = detections.find { |detection| detection.importer == chosen.key && detection.type == upload.detected_type }
        return { status: 'recognized', reason: nil, params_json: merged_params(upload, chosen, document, match).to_json }
      end

      top, second = detections
      unless top
        return decision('needs_review', nil, unknown_reason(document)).merge(detected_type: nil, detected_label: nil, confidence: nil, detected_reason: nil)
      end

      fields = { detected_type: top.type, detected_label: top.label, confidence: top.percent, detected_reason: top.reason }
      importer = top.importer && Registry.find(top.importer)
      fields.merge(
        if top.importer.nil?
          decision('needs_review', nil, "Recognized as #{top.label} (#{top.percent}%), but Rupert has no importer for it yet. The file is kept; use Re-run recognition after one ships.")
        elsif importer.nil? || !importer.available?
          decision('needs_review', nil, "Recognized as #{top.label} (#{top.percent}%), but that importer is not installed yet. The file is kept; use Re-run recognition after it ships.")
        elsif top.confidence < AUTO_CONFIDENCE
          decision('needs_review', nil, "Possibly #{top.label} (#{top.percent}%), which is not certain enough to go ahead. Confirm the type below, or choose another importer.")
        elsif second && top.confidence - second.confidence < MARGIN && second.type != top.type
          decision('needs_review', nil, "Could be #{top.label} (#{top.percent}%) or #{second.label} (#{second.percent}%). Say which.")
        else
          decision('recognized', top.importer, nil).merge(params_json: merged_params(upload, importer, document, top).to_json)
        end
      )
    end

    def self.decision(status, importer_key, reason)
      { status: status, importer_key: importer_key, reason: reason, operator_chosen: false }
    end

    # Suggestions fill blanks only; anything a person already typed stays.
    def self.merged_params(upload, importer, document, detection)
      suggested = detection ? importer.new.suggested_params(document, detection) : {}
      suggested.merge(upload.params.compact_blank)
    end

    def self.unknown_reason(document)
      case document.format
      when 'pdf' then 'PDF documents are kept as evidence; Rupert does not read them, so there is nothing to import. Download the original when you need it.'
      when 'xlsx' then 'Rupert does not recognize this workbook. If it is a report, open it in Excel and Save As CSV, then upload that.'
      when 'json' then "Rupert has no importer for this JSON (#{document.json_outline.downcase}). It is kept as received."
      else 'Rupert could not tell what this file is from its columns or title. It is kept as received; choose an importer if you know what it is.'
      end
    end
  end
end
