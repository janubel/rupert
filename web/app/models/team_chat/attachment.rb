# frozen_string_literal: true

module TeamChat
  # An image or file posted with a message. The type comes from the bytes, not
  # from what the browser claimed, and only a short list of types is accepted.
  class Attachment < ApplicationRecord
    include TenantScoped

    MAX_BYTES = 8.megabytes
    MAX_PER_MESSAGE = 4
    MAGIC = {
      'image/png' => ["\x89PNG\r\n\x1A\n".b], 'image/jpeg' => ["\xFF\xD8\xFF".b], 'image/gif' => ['GIF87a'.b, 'GIF89a'.b],
      'application/pdf' => ['%PDF-'.b]
    }.freeze
    TEXT_TYPES = { '.csv' => 'text/csv', '.txt' => 'text/plain' }.freeze
    IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

    belongs_to :room, class_name: 'TeamChat::Room'
    belongs_to :message, class_name: 'TeamChat::Message'

    validates :filename, :content_type, presence: true
    validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_BYTES }

    # The served type for these bytes, or nil when the file is not allowed.
    def self.sniff(bytes, filename)
      head = bytes.to_s.byteslice(0, 16).to_s.b
      found = MAGIC.find { |_type, signatures| signatures.any? { |signature| head.start_with?(signature) } }&.first
      return found if found
      return 'image/webp' if head.start_with?('RIFF'.b) && head.byteslice(8, 4) == 'WEBP'.b

      text = TEXT_TYPES[File.extname(filename.to_s).downcase]
      text if text && !bytes.to_s.byteslice(0, 8_192).to_s.include?("\x00") && bytes.to_s.dup.force_encoding('UTF-8').valid_encoding?
    end

    # Builds an attachment from an uploaded file, or returns an error string.
    def self.from_upload(upload)
      return 'That is not a file.' unless upload.respond_to?(:read)

      bytes = upload.read(MAX_BYTES + 1).to_s
      name = clean_name(upload.original_filename)
      return "#{name} is larger than #{MAX_BYTES / 1.megabyte} MB." if bytes.bytesize > MAX_BYTES
      return "#{name} is empty." if bytes.empty?

      type = sniff(bytes, name)
      return "#{name} is not a supported file. Use an image (PNG, JPEG, GIF, WebP), a PDF, a CSV or a text file." unless type

      new(filename: name, content_type: type, byte_size: bytes.bytesize, data: bytes)
    end

    def self.clean_name(name)
      base = File.basename(name.to_s).scrub('').gsub(/[^\w.\- ()]/, '_').strip
      base.presence&.first(120) || 'file'
    end

    def image? = IMAGE_TYPES.include?(content_type)

    def as_payload(room)
      { id: id, name: filename, type: content_type, size: byte_size, image: image?,
        url: Rails.application.routes.url_helpers.team_chat_attachment_path(room, id) }
    end
  end
end
