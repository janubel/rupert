# frozen_string_literal: true

# Deploys run `db:migrate`; log it (lib/ops_log/migrations.rb).
namespace :ops_log do
  task migrate_started: :environment do
    OpsLog::Migrations.started
  end
end

if Rake::Task.task_defined?('db:migrate')
  Rake::Task['db:migrate'].enhance(['ops_log:migrate_started']) { OpsLog::Migrations.finished }
end
