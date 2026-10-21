# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require 'time'

# Build-time only. All measurements refer to immutable Git objects, never the
# working tree or business database. No network calls or external dependencies.
class NightlyRelease
  SOURCE_EXTENSIONS = %w[.rb .erb .js .mjs .jsx .ts .tsx .css .html .py .sh .sql .yml .yaml .rs].freeze
  SOURCE_ROOTS = %w[web/app/ web/config/ web/lib/ web/db/migrate/ web/test/ bin/ deploy/ mobile/ core/].freeze
  EXCLUDED = %r{(?:\A|/)(?:node_modules|vendor|coverage|fixtures/files|assets/builds|dist|target)/|(?:lock|\.min\.js)\z}

  def initialize(root:, revision: 'HEAD', base: nil)
    @root = Pathname(root)
    @revision = git('rev-parse', '--verify', "#{revision}^{commit}").strip
    raise 'Full Git history is required for release totals' if git('rev-parse', '--is-shallow-repository').strip == 'true'

    @at = Time.iso8601(git('show', '-s', '--format=%cI', @revision).strip).utc
    @base = base || previous_nightly || git('rev-list', '--first-parent', '-1', "--before=#{(@at - 86_400).iso8601}", @revision).strip
    @base = git('rev-parse', '--verify', "#{@base}^{commit}").strip unless @base.empty?
    raise 'Release baseline is not an ancestor of the source revision' unless @base.empty? || ancestor?(@base)
  end

  def generate
    fixes = confirmed_fixes
    nightly_commits = commits(range)
    {
      'schema_version' => 1,
      'revision' => @revision,
      'version' => git('show', "#{@revision}:VERSION").strip,
      'as_of' => @at.iso8601,
      'base_revision' => @base.empty? ? nil : @base,
      'nightly' => measure(range).merge('confirmed_bugs_fixed' => fixes.count { |fix| nightly_commits.include?(fix.fetch('commit')) }),
      'cumulative' => measure(@revision).merge('confirmed_bugs_fixed' => nil, 'tracked_fixes' => fixes.length),
      'source_lines' => source_lines,
      'confirmed_fixes' => fixes,
      'counting_rules' => {
        'patches' => 'Unique non-merge commits changing scoped source files; merge commits and metadata-only commits excluded.',
        'lines' => 'Added/deleted text lines per non-merge commit (not net tree diff); no rename detection. Includes tests, blanks and comments.',
        'source' => 'web/app, web/config, web/lib, web/db/migrate, web/test, bin, deploy, mobile and historical core; selected code extensions and extensionless bin scripts. Excludes vendored/generated files, lockfiles, docs and legacy.',
        'bugs' => 'Distinct reviewed fixes in config/confirmed_release_fixes.json, reachable at this revision. Registry is incomplete: cumulative historical bug total is unavailable.',
        'window' => 'Previous reachable nightly tag to source revision; first run uses the first-parent commit preceding the source revision by 24 hours.'
      }
    }
  end

  def notes(metadata)
    stable = git('tag', '--merged', @revision, '--list', 'v[0-9]*', '--sort=-version:refname').lines.map(&:strip).find { |tag| !tag.include?('-') }
    release_range = stable ? "#{stable}..#{@revision}" : @revision
    totals = metadata.fetch('nightly')
    lines = ["# Rupert nightly — #{@at.strftime('%Y-%m-%d')}", '',
      "Source: `#{@revision}` · version #{metadata.fetch('version')} · as of #{@at.iso8601}.",
      "Nightly baseline: `#{@base.empty? ? 'repository root' : @base}`.", '',
      "Nightly: **#{totals.fetch('patch_commits')} patch commits**, **#{totals.fetch('confirmed_bugs_fixed')} confirmed fixes**, **+#{totals.fetch('lines_added')} / −#{totals.fetch('lines_deleted')} source lines**.",
      "Cumulative: #{metadata.dig('cumulative', 'patch_commits')} patch commits; +#{metadata.dig('cumulative', 'lines_added')} / −#{metadata.dig('cumulative', 'lines_deleted')} lines. Current source: #{metadata.fetch('source_lines')} physical lines (includes tests, blanks and comments).", '',
      'Historical bug totals are unavailable; confirmed fixes below are a reviewed, incomplete registry.', '', '## Confirmed fixes', '']
    metadata.fetch('confirmed_fixes').each do |fix|
      lines << "- #{fix.fetch('summary')} ([source](https://github.com/techmore/rupert/commit/#{fix.fetch('commit')}))."
    end
    lines.concat(['', "## Integrated changes since #{stable || 'repository root'}", '',
      'Commit subjects below describe source changes, not independent claims of production acceptance.', ''])
    git('log', '--no-merges', '--format=%H%x09%s', release_range).each_line do |line|
      sha, subject = line.strip.split("\t", 2)
      # Commit subjects are repository text, not Markdown instructions/HTML.
      subject = subject.to_s.gsub(/[<>\[\]`*_]/, '')
      lines << "- #{subject} ([#{sha[0, 12]}](https://github.com/techmore/rupert/commit/#{sha}))."
    end
    lines.concat(['', '## Scope and acceptance', '',
      'Nightly prerelease of integrated source. A GitHub release does not establish vendor/payment, device or operator acceptance. Deployment must be verified separately against X-Rupert-Build.',
      'See the attached release-metadata.json for exact counting rules and source ranges.', ''])
    lines.join("\n")
  end

  private

  def git(*args)
    output, error, status = Open3.capture3('git', '-c', "safe.directory=#{@root}", '-C', @root.to_s, *args)
    raise "Git measurement failed: #{error.strip}" unless status.success?

    output
  end

  def ancestor?(sha)
    _, _, status = Open3.capture3('git', '-c', "safe.directory=#{@root}", '-C', @root.to_s, 'merge-base', '--is-ancestor', sha, @revision)
    status.success?
  end

  def previous_nightly
    # Rebuilding an already tagged source must retain its previous baseline.
    git('tag', '--merged', @revision, '--list', 'nightly-*', '--sort=-creatordate').lines.each do |line|
      sha = git('rev-parse', "#{line.strip}^{commit}").strip
      return sha unless sha == @revision
    end
    nil
  end

  def range = @base.empty? ? @revision : "#{@base}..#{@revision}"
  def commits(selection) = git('rev-list', '--no-merges', selection).lines.map(&:strip)

  def source?(path)
    return false if path.match?(EXCLUDED)
    return false unless SOURCE_ROOTS.any? { |prefix| path.start_with?(prefix) }

    SOURCE_EXTENSIONS.include?(File.extname(path)) || (path.start_with?('bin/') && File.extname(path).empty?)
  end

  def measure(selection)
    patches = {}
    added = deleted = 0
    sha = nil
    git('log', '--root', '--no-merges', '--no-renames', '--numstat', '--format=commit:%H', selection).each_line do |line|
      if line.start_with?('commit:')
        sha = line.strip.delete_prefix('commit:')
      else
        plus, minus, path = line.chomp.split("\t", 3)
        next unless path && source?(path) && plus.match?(/\A\d+\z/) && minus.match?(/\A\d+\z/)

        patches[sha] = true
        added += plus.to_i
        deleted += minus.to_i
      end
    end
    { 'patch_commits' => patches.length, 'lines_added' => added, 'lines_deleted' => deleted }
  end

  def source_lines
    paths = git('ls-tree', '-r', '--name-only', @revision).lines.map(&:strip).select { |path| source?(path) }
    return 0 if paths.empty?

    output, _, status = Open3.capture3('git', '-c', "safe.directory=#{@root}", '-C', @root.to_s, 'grep', '-I', '-c', '^', @revision, '--', *paths)
    raise 'Could not count source lines' unless [0, 1].include?(status.exitstatus)

    output.lines.sum { |line| line.rpartition(':').last.to_i }
  end

  def confirmed_fixes
    raw, _, status = Open3.capture3('git', '-c', "safe.directory=#{@root}", '-C', @root.to_s, 'show', "#{@revision}:web/config/confirmed_release_fixes.json")
    return [] unless status.success?

    JSON.parse(raw).fetch('fixes').uniq { |fix| fix.fetch('id') }.select do |fix|
      fix.fetch('commit').match?(/\A[0-9a-f]{40}\z/) && ancestor?(fix.fetch('commit'))
    end
  end
end
