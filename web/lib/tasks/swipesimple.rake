# frozen_string_literal: true

namespace :swipesimple do
  # Owner-run only; never part of deploy. Read-only toward SwipeSimple.
  #   bin/rails "swipesimple:backfill_reports[2025-01-01,2026-10-19]"
  # Optional: TENANT_ID=... (required when several workspaces have SwipeSimple), PAUSE=seconds (default 2).
  desc 'One-time pull of SwipeSimple tax and sales reports, month by month (read-only)'
  task :backfill_reports, %i[from to] => :environment do |_task, args|
    from = Date.iso8601(args[:from].to_s)
    to = args[:to].present? ? Date.iso8601(args[:to]) : SwipesimpleWeb::ReportStore.today - 1
    connections = PosConnection.unscoped.where(provider: 'swipesimple')
    connections = connections.where(tenant_id: ENV['TENANT_ID']) if ENV['TENANT_ID'].present?
    abort 'Expected exactly one SwipeSimple connection; set TENANT_ID.' unless connections.one?

    connection = connections.first
    Current.set(tenant: connection.tenant) do
      result = SwipesimpleWeb::Backfill.call(connection: connection, from: from, to: to, pause: ENV.fetch('PAUSE', '2').to_f,
        log: ->(line) { puts line })
      puts "Done: #{result[:months]} months of tax and sales reports stored for #{result[:accounts]} account(s) for #{result[:from]}..#{result[:to]}."
    end
  rescue Date::Error
    abort 'Use dates in YYYY-MM-DD format, e.g. bin/rails "swipesimple:backfill_reports[2025-01-01,2026-10-19]".'
  rescue SwipesimpleWeb::Client::Error, ArgumentError => e
    abort "Stopped: #{e.message} Months already stored were kept."
  end
end
