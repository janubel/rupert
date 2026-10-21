# frozen_string_literal: true

# Build pipeline for `shopify app build` (web/shopify.web.toml points here) and
# local parity with CI (.github/workflows/ci.yml): compile Tailwind CSS, then
# precompile assets.
namespace :build do
  desc 'Measure immutable source history for the running build header'
  task :metadata do
    # Git-free images may carry a pre-generated manifest. Never substitute
    # measurements from another checkout; BuildInfo rejects revision mismatch.
    next unless Rails.root.parent.join('.git').exist?

    require Rails.root.join('lib/nightly_release')
    release = NightlyRelease.new(root: Rails.root.parent)
    path = Rails.root.join('config/release_metadata.json')
    File.write("#{path}.tmp", "#{JSON.pretty_generate(release.generate)}\n")
    File.rename("#{path}.tmp", path)
  end

  desc 'Compile Tailwind CSS and precompile assets'
  task all: ['tailwindcss:build', 'assets:precompile']
end

Rake::Task['assets:precompile'].enhance(['build:metadata'])
