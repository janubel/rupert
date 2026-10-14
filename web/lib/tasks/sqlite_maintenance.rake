# frozen_string_literal: true

namespace :ops do
  namespace :sqlite do
    desc 'Read SQLite configuration and space metrics (no business data)'
    task report: :environment do
      puts JSON.pretty_generate(SqliteMaintenance.report)
    end

    desc 'Refresh SQLite planner statistics with bounded PRAGMA optimize'
    task optimize: :environment do
      abort 'SQLite adapter required; no changes made' unless SqliteMaintenance.optimize!

      puts 'SQLite planner statistics optimized; business records unchanged.'
    end
  end
end
