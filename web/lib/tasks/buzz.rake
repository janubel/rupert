# frozen_string_literal: true

namespace :buzz do
  desc 'Print the @rupert agent prompt (MODE=text_only|acp, default acp), e.g. to refresh docs/ops/buzz-agent-prompt.txt'
  task prompt: :environment do
    puts BuzzAgentPrompt.render(mode: ENV.fetch('MODE', 'acp').to_sym)
  end

  desc 'Create a Buzz key for every active person who may post in the WebUI Buzz client and print the public keys ' \
       '(hex and npub) for deploy/ser8/buzz/add-member.sh. Prints no private key.'
  task person_keys: :environment do
    Tenant.where(status: 'active').find_each do |tenant|
      Current.tenant = tenant
      User.where(tenant_id: tenant.id, active: true).find_each do |user|
        next if user.employee? || !user.can?('buzz.post')

        key = BuzzPersonKey.for(user)
        puts [tenant.id, user.id, user.display_name.to_s.tr("\t\n", '  '), key.pubkey, key.npub].join("\t")
      end
    ensure
      Current.reset
    end
  end
end
