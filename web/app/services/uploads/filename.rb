# frozen_string_literal: true

module Uploads
  # A filename is attacker-controlled text. It is used only as a label: never in
  # a filesystem path, a shell or a header without this cleaning.
  module Filename
    MAX_LENGTH = 120
    BIDI_AND_CONTROL = /[\u0000-\u001F\u007F-\u009F​-‏‪-‮⁦-⁩﻿]/

    def self.clean(raw)
      name = raw.to_s.dup.force_encoding(Encoding::UTF_8)
      name = name.scrub('_').unicode_normalize(:nfkc).gsub(BIDI_AND_CONTROL, '')
      name = File.basename(name.tr('\\', '/'))
      name = name.gsub(/[^\p{L}\p{N}._ -]/, '_').gsub(/\s+/, ' ').gsub(/_{2,}/, '_').strip
      name = name.sub(/\A[.\s]+/, '')
      extension = File.extname(name)
      stem = name.delete_suffix(extension).first(MAX_LENGTH - extension.length)
      cleaned = "#{stem}#{extension}"
      cleaned.empty? ? 'upload' : cleaned
    end

    def self.extension(name)
      File.extname(name.to_s).downcase
    end
  end
end
