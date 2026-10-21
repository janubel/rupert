# frozen_string_literal: true

require 'base64'
require 'digest'

module Uploads
  # The single front door. Browser, API and the host drop directory all call this.
  # It keeps the original once (encrypted, byte for byte), refuses what it cannot
  # safely keep, recognizes what it kept, and writes one audit line. It never
  # opens a file's contents beyond decoding them for sniffing, and never changes
  # a business record.
  class Intake
    Error = Class.new(StandardError)
    Result = Struct.new(:upload, :created, keyword_init: true)
    DAILY_LIMIT = 500
    STORAGE_LIMIT = 2 * 1024 * 1024 * 1024

    def self.call(...) = new(...).call

    def initialize(file, filename:, origin:, actor: nil, content_type: nil, token_label: nil)
      @file = file
      @filename = Filename.clean(filename)
      @origin = origin
      @actor = actor
      @content_type = content_type.to_s.first(100).presence
      @token_label = token_label
    end

    def call
      raise Error, 'An active workspace is required.' unless Current.tenant&.status == 'active'

      check_capacity!
      refusal = prefilter
      return reject(refusal, byte_size: @declared_size.to_i) if refusal

      bytes = read_bytes
      return reject("The file is larger than #{Limits.human_max}.", byte_size: @declared_size || Limits::MAX_FILE_BYTES + 1) if bytes.nil?
      return reject('The file is empty.', byte_size: 0) if bytes.empty?

      reason = Validator.check(bytes, format)
      return reject(reason, bytes: bytes) if reason

      keep(bytes)
    end

    private

    # Over capacity is an error, not a new row: a flood must not keep growing the table.
    def check_capacity!
      raise Error, "This workspace has reached its limit of #{DAILY_LIMIT} uploads in 24 hours. Try again tomorrow, or ask an administrator." if Upload.where('created_at > ?', 1.day.ago).count >= DAILY_LIMIT
      raise Error, 'The inbox storage limit (2 GiB) has been reached. Ask an administrator.' if Upload.where(retained: true).sum(:byte_size) >= STORAGE_LIMIT
    end

    def format = Limits::FORMATS[Filename.extension(@filename)]

    def prefilter
      @declared_size = @file.size if @file.respond_to?(:size)
      return "Unsupported file type “#{Filename.extension(@filename).presence || 'none'}”. Send #{Limits::FORMATS.keys.to_sentence(last_word_connector: ', or ')}." unless format

      'The file is empty.' if @declared_size&.zero?
    end

    # Reads at most one byte past the cap so an oversized body is never held whole.
    def read_bytes
      return nil if @declared_size && @declared_size > Limits::MAX_FILE_BYTES

      data = @file.respond_to?(:read) ? @file.read(Limits::MAX_FILE_BYTES + 1) : @file.to_s
      data = data.to_s.b
      data.bytesize > Limits::MAX_FILE_BYTES ? nil : data
    end

    def keep(bytes)
      sha = Digest::SHA256.hexdigest(bytes)
      upload = nil
      created = false
      Upload.transaction do
        # Serialize with SQLite's writer lock so two identical uploads cannot both be kept.
        Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
        earlier = Upload.find_by(sha256: sha, retained: true)
        if earlier
          upload = create_row(status: 'duplicate', byte_size: bytes.bytesize, sha256: sha, duplicate_of_id: earlier.id,
            reason: duplicate_reason(earlier))
        else
          upload = create_row(status: 'received', byte_size: bytes.bytesize, sha256: sha, retained: true, content_base64: Base64.strict_encode64(bytes))
          created = true
        end
      end
      recognize(upload) if created
      Audit.record(created ? 'received' : 'duplicate', upload, actor: @actor)
      Result.new(upload: upload, created: created)
    end

    def recognize(upload)
      Recognizer.call(upload)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { uploads_recognize: upload.id })
      upload.update!(reason: 'Recognition failed unexpectedly. The file is kept; use Re-run recognition.')
    end

    def reject(reason, bytes: nil, byte_size: nil)
      upload = create_row(status: 'rejected', reason: reason, byte_size: byte_size || bytes&.bytesize || 0, sha256: bytes && Digest::SHA256.hexdigest(bytes))
      Audit.record('rejected', upload, actor: @actor)
      Result.new(upload: upload, created: false)
    end

    def create_row(attrs)
      Upload.create!({ filename: @filename, file_format: format, origin: @origin, client_content_type: @content_type, uploaded_by: @actor,
                       uploaded_by_name: @actor && (@actor.display_name || @actor.email), via_token_label: @token_label }.merge(attrs))
    end

    def duplicate_reason(earlier)
      "Identical to upload ##{earlier.id}, received #{earlier.created_at.utc.strftime('%Y-%m-%d %H:%M UTC')}. The file was not stored a second time."
    end
  end
end
