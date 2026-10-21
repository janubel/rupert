# frozen_string_literal: true

module Uploads
  # A hint about where a file came from, from the file name alone. The strongest
  # evidence is the importer's own detection; this only fills the gap and is
  # shown as a guess.
  module SourceGuess
    HINTS = {
      /quickbooks|\bqbo\b|\bqb[-_ ]/i => 'QuickBooks', /square/i => 'Square', /swipe/i => 'SwipeSimple',
      /authorize|auth[-_ ]?net/i => 'Authorize.net', /\bnab\b|\biris\b|daily[-_ ]?deposits?/i => 'NAB / IRIS',
      /c[-_ ]?trax/i => 'C-Trax', /shopify/i => 'Shopify', /timesheet|time[-_ ]?card/i => 'Timesheets',
      /statement|checking|savings|\bbank\b|chase|wells|\bbofa\b/i => 'Bank'
    }.freeze

    def self.call(filename, detections)
      from_detection = detections.first&.source
      return from_detection if from_detection.present? && detections.first.confidence >= 0.5

      HINTS.find { |pattern, _| filename.to_s.match?(pattern) }&.last || from_detection
    end
  end
end
