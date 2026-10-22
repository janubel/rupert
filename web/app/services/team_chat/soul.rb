# frozen_string_literal: true

module TeamChat
  # Rupert's persona for team chat: identity, voice, values and boundaries, kept
  # in config/team_chat/soul.md so it can be edited without touching code. Tools,
  # room context and output rules are added by TeamChat::Agent.
  module Soul
    PATH = Rails.root.join('config/team_chat/soul.md')

    def self.text
      @text = nil if Rails.env.development?
      @text ||= File.read(PATH).strip
    end
  end
end
