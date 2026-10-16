# frozen_string_literal: true

namespace :square do
  desc 'Enable or disable tenant read-only timecard refresh; ENABLED=1 enables the 15-minute schedule'
  task timecards_schedule: :environment do
    raise ArgumentError, 'ENABLED must be 1 or 0' unless %w[0 1].include?(ENV['ENABLED'])
    Current.tenant = Tenant.find(ENV.fetch('TENANT_ID'))
    Current.user = User.find(ENV.fetch('ACTOR_ID'))
    SquareTimecardSync.configure!(enabled: ENV.fetch('ENABLED') == '1')
    puts({ enabled: SquareTimecardSync.enabled?, interval_minutes: 15 }.to_json)
  ensure
    Current.reset
  end

  desc 'Read Square timecards and preview their employee matches; APPLY=1 imports local history only'
  task timecards: :environment do
    Current.tenant = Tenant.find(ENV.fetch('TENANT_ID'))
    Current.user = User.find(ENV.fetch('ACTOR_ID'))
    puts SquareTimecardImport.new.call(apply: ENV['APPLY'] == '1').to_json
  ensure
    Current.reset
  end
end
