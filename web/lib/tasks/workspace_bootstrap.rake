# frozen_string_literal: true

namespace :workspace do
  desc 'Bootstrap a clean isolated workspace from verified provisioning JSON on stdin'
  task bootstrap: :environment do
    data = JSON.parse($stdin.read(16_385))
    WorkspaceBootstrap.call(data)
    puts 'Workspace bootstrap complete.'
  end
end
