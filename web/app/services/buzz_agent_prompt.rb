# frozen_string_literal: true

# The one definition of the @rupert Buzz agent: who it is, what it is for and
# what it must never do. Every way of running the agent reads it from here, so
# the prompt cannot drift between them:
#
#   :text_only  OpencodeChatAgent (opencode run, no tools)
#   :acp        the buzz-acp harness in the sandboxed agent container (deploy/ser8/agent); docs/ops/buzz-agent-prompt.txt
#               is this text rendered, kept in sync by test and `rake buzz:prompt`
#
# The text lives in config/buzz_agent/*.md so it can be reviewed like prose.
class BuzzAgentPrompt
  DIR = Rails.root.join('config/buzz_agent')
  MODES = %i[text_only acp].freeze

  NAME = 'Rupert'
  HANDLE = '@rupert'

  class << self
    # The public profile line shown on Rupert's Buzz card and published as the
    # agent's Nostr profile.
    def about
      'Rupert, the team\'s AI agent. Answers questions about the business and how Rupert works, ' \
        'explains sync, stock and count notices, and points you to the right page. Read-only: it cannot change anything.'
    end

    def render(mode: :text_only)
      raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

      [read('core'), read(mode.to_s)].join("\n")
    end

    private

    def read(name)
      DIR.join("#{name}.md").read.strip + "\n"
    end
  end
end
