# frozen_string_literal: true

# A stand-in for Google::Apis::DriveV3::DriveService with a few invented files.
class FakeDrive
  Meta = Struct.new(:id, :name, :size, :mime_type, :parents, :trashed, :md5_checksum, :modified_time, keyword_init: true)
  Page = Struct.new(:files, :next_page_token)

  attr_reader :queries, :downloads

  def initialize(files: {}, folders: {})
    @files = files   # id => { meta:, bytes: }
    @folders = folders
    @queries = []
    @downloads = []
  end

  def self.file(id, name, bytes, parents: ['folder-1'], mime: 'text/csv', trashed: false, md5: nil, size: nil)
    { meta: Meta.new(id: id, name: name, size: size || bytes.bytesize, mime_type: mime, parents: parents, trashed: trashed,
      md5_checksum: md5 || Digest::MD5.hexdigest(bytes), modified_time: Time.utc(2026, 10, 1)), bytes: bytes }
  end

  def list_files(q:, **)
    @queries << q
    if q.include?('google-apps.folder') && q.include?('mimeType =')
      Page.new(@folders.map { |id, name| Meta.new(id: id, name: name, mime_type: 'application/vnd.google-apps.folder') }, nil)
    else
      Page.new(@files.values.map { |f| f[:meta] }.select { |m| m.parents.include?('folder-1') && !m.trashed }, nil)
    end
  end

  def get_file(id, fields: nil, download_dest: nil)
    if download_dest
      @downloads << id
      download_dest.write(@files.fetch(id)[:bytes])
      return nil
    end
    return Meta.new(id: id, name: @folders[id], mime_type: 'application/vnd.google-apps.folder', trashed: false) if @folders.key?(id)

    @files.fetch(id)[:meta]
  end

  def get_about(**)
    Struct.new(:user).new(Struct.new(:email_address).new('owner@example.test'))
  end
end
