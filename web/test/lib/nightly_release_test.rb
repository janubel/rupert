# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require Rails.root.join('lib/nightly_release')

class NightlyReleaseTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @directory = Dir.mktmpdir
    @root = Pathname(@directory)
    git('init', '-q')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    write('VERSION', "0.2.0\n")
    write('web/app/example.rb', "one\ntwo\n")
    write('docs/example.md', "not source\n")
    @base = commit('Initial fixture')
  end

  teardown { FileUtils.remove_entry(@directory) }

  test 'counts source churn once and excludes docs metadata lockfiles and merge commits' do
    write('web/app/example.rb', "one\nthree\nfour\n")
    write('mobile/package-lock.json', "excluded\n")
    fix = commit('Fixture fix')
    write('web/config/confirmed_release_fixes.json', { fixes: [
      { id: 'one-bug', commit: fix, summary: 'A reviewed fix' },
      { id: 'one-bug', commit: fix, summary: 'Duplicate evidence' }
    ] }.to_json)
    write('docs/example.md', "changed documentation\n")
    commit('Metadata only')
    metadata = NightlyRelease.new(root: @root, base: @base).generate
    assert_equal({ 'patch_commits' => 1, 'lines_added' => 2, 'lines_deleted' => 1, 'confirmed_bugs_fixed' => 1 }, metadata.fetch('nightly'))
    assert_equal 2, metadata.dig('cumulative', 'patch_commits')
    assert_equal 3, metadata.fetch('source_lines')
    assert_nil metadata.dig('cumulative', 'confirmed_bugs_fixed')
    assert_equal 1, metadata.fetch('confirmed_fixes').length
    assert_equal metadata, NightlyRelease.new(root: @root, base: @base).generate
  end

  test 'a merge does not count side-branch source twice' do
    branch = git('branch', '--show-current').strip
    git('checkout', '-qb', 'fixture-side')
    write('web/app/other.rb', "other\n")
    commit('Side change')
    git('checkout', '-q', branch)
    git('merge', '--no-ff', '-m', 'Merge fixture', 'fixture-side')
    metadata = NightlyRelease.new(root: @root, base: @base).generate
    assert_equal 1, metadata.dig('nightly', 'patch_commits')
    assert_equal 1, metadata.dig('nightly', 'lines_added')
  end

  test 'rebuilding the nightly tag skips that tag as a baseline' do
    git('tag', 'nightly-previous', @base)
    write('web/app/example.rb', "three\n")
    head = commit('Next build')
    git('tag', 'nightly-current', head)
    metadata = NightlyRelease.new(root: @root).generate
    assert_equal @base, metadata.fetch('base_revision')
    assert_equal 1, metadata.dig('nightly', 'patch_commits')
  end

  test 'rejects a baseline outside the source history' do
    git('checkout', '--orphan', 'unrelated')
    git('rm', '-rf', '.')
    write('VERSION', "0.2.0\n")
    other = commit('Unrelated history')
    assert_raises(RuntimeError) { NightlyRelease.new(root: @root, revision: @base, base: other) }
  end

  test 'refuses incomplete history rather than publishing partial cumulative totals' do
    @root.join('.git/shallow').write("#{@base}\n")
    error = assert_raises(RuntimeError) { NightlyRelease.new(root: @root) }
    assert_match(/Full Git history/, error.message)
  end

  private

  def write(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def commit(message)
    git('add', '.')
    git('commit', '-qm', message)
    git('rev-parse', 'HEAD').strip
  end

  def git(*args)
    output, error, status = Open3.capture3('git', '-C', @directory, *args)
    raise error unless status.success?

    output
  end
end
