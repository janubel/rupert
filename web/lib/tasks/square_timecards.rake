# frozen_string_literal: true

namespace :square do
  desc 'Read Square timecards and preview their employee matches; APPLY=1 imports local history only'
  task timecards: :environment do
    Current.tenant = Tenant.find(ENV.fetch('TENANT_ID'))
    Current.user = User.find(ENV.fetch('ACTOR_ID'))
    puts SquareTimecardImport.new.call(apply: ENV['APPLY'] == '1').to_json
  ensure
    Current.reset
  end
end
