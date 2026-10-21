# frozen_string_literal: true

module Uploads
  # Every size and shape cap in one place so the browser form, the API, the drop
  # directory and the docs agree.
  module Limits
    MAX_FILE_BYTES = 10 * 1024 * 1024
    MAX_FILES_PER_REQUEST = 10
    MAX_REQUEST_BYTES = 25 * 1024 * 1024

    FORMATS = { '.csv' => 'csv', '.txt' => 'text', '.json' => 'json', '.pdf' => 'pdf', '.xlsx' => 'xlsx' }.freeze
    FORMAT_LABELS = { 'csv' => 'CSV', 'text' => 'Text', 'json' => 'JSON', 'pdf' => 'PDF', 'xlsx' => 'Excel' }.freeze

    # An .xlsx is a zip. These stop zip bombs before anything is inflated.
    ZIP_MAX_ENTRIES = 500
    ZIP_MAX_UNCOMPRESSED = 100 * 1024 * 1024
    ZIP_MAX_RATIO = 100
    ZIP_PART_READ = 8 * 1024 * 1024

    SAMPLE_ROWS = 60
    PREVIEW_ROWS = 25
    PREVIEW_COLS = 30
    PREVIEW_CELL = 200
    JSON_MAX_BYTES = 2 * 1024 * 1024

    def self.accept_attribute = FORMATS.keys.join(',')
    def self.human_max = '10 MiB'
  end
end
