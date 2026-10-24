# frozen_string_literal: true

namespace :ctrax do
  # Owner-run only; never part of deploy. Read-only toward C-Trax: reads each day's orders and stores the day.
  #   bin/rails "ctrax:backfill_sales[2025-10-01,2026-08-31]"   (TENANT_ID=... when several workspaces, PAUSE=seconds)
  desc 'Read C-Trax daily sales for a past date range, one day at a time (read-only)'
  task :backfill_sales, %i[from to] => :environment do |_task, args|
    from = Date.iso8601(args[:from].to_s)
    to = args[:to].present? ? Date.iso8601(args[:to]) : Date.yesterday
    abort 'Choose an ordered range that does not end in the future.' if from > to || to > Date.current
    abort 'Choose 400 days or fewer.' if (to - from).to_i >= 400

    connections = PosConnection.unscoped.where(provider: 'ctrax', vendor_approved: true)
    connections = connections.where(tenant_id: ENV['TENANT_ID']) if ENV['TENANT_ID'].present?
    abort 'Expected exactly one approved C-Trax connection; set TENANT_ID.' unless connections.one?

    connection = connections.first
    pause = ENV.fetch('PAUSE', '1').to_f
    Current.set(tenant: connection.tenant) do
      (from..to).each_with_index do |day, index|
        sleep(pause) if index.positive? && pause.positive?
        result = Ctrax::SalesSync.call(connection: connection.reload, date: day)
        puts "#{result[:date]}: #{result[:stores]} stores, #{result[:orders]} orders"
      end
    end
  rescue Date::Error
    abort 'Use dates like 2025-10-01.'
  rescue Ctrax::Client::Error => e
    abort "Stopped: #{e.message} Days already stored were kept."
  end
end
