# frozen_string_literal: true

module Projects
  # A small file kept with a task. Untrusted: the type comes from the file's
  # name and bytes against a short allow-list, it is only ever served as a
  # download, and it is never interpreted.
  class TaskAttachment < ApplicationRecord
    include TenantScoped

    self.table_name = 'task_attachments'

    MAX_BYTES = 5.megabytes
    MAX_PER_TASK = 10
    TYPES = {
      '.png' => ['image/png', "\x89PNG".b], '.jpg' => ['image/jpeg', "\xFF\xD8\xFF".b], '.jpeg' => ['image/jpeg', "\xFF\xD8\xFF".b],
      '.gif' => ['image/gif', 'GIF8'.b], '.pdf' => ['application/pdf', '%PDF'.b],
      '.txt' => ['text/plain', nil], '.csv' => ['text/csv', nil]
    }.freeze

    belongs_to :task, class_name: 'Projects::Task'
    belongs_to :user, optional: true

    validates :filename, :content_type, presence: true
    validates :byte_size, numericality: { less_than_or_equal_to: MAX_BYTES, message: 'is over the 5 MB limit' }
    validate :room_on_task, on: :create

    # Returns an unsaved attachment for an uploaded file, or one carrying errors.
    def self.from_upload(task, upload, user)
      name = File.basename(upload.original_filename.to_s).gsub(/[^\w.\- ]/, '_').strip.last(120)
      bytes = upload.read(MAX_BYTES + 1).to_s.b
      type, magic = TYPES[File.extname(name).downcase]
      attachment = new(task: task, user: user, filename: name.presence || 'file', byte_size: bytes.bytesize,
        content_type: type || 'application/octet-stream', body: bytes)
      attachment.errors.add(:base, 'Only PNG, JPG, GIF, PDF, TXT and CSV files can be attached') unless type
      attachment.errors.add(:base, 'That file does not look like its extension') if type && magic && !bytes.start_with?(magic)
      attachment
    end

    def valid_upload?
      errors.empty? && valid?
    end

    private

    def room_on_task
      errors.add(:base, "A task holds at most #{MAX_PER_TASK} files") if task && task.attachments.count >= MAX_PER_TASK
    end
  end
end
