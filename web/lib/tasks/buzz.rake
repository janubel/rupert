# frozen_string_literal: true

namespace :buzz do
  desc 'Print the @rupert agent prompt (MODE=text_only|acp, default acp), e.g. to refresh docs/ops/buzz-agent-prompt.txt'
  task prompt: :environment do
    puts BuzzAgentPrompt.render(mode: ENV.fetch('MODE', 'acp').to_sym)
  end
end
