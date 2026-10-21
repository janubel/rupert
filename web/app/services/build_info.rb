# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

# Immutable identity of the source loaded when this process started.
class BuildInfo
  REVISION = /\A[0-9a-f]{40,64}\z/i
  attr_reader :revision, :built_at, :release_totals

  def initialize(revision:, built_at: nil, release_totals: nil)
    @revision = revision.to_s.match?(REVISION) ? revision.downcase.freeze : 'unversioned'
    @release_totals = release_totals if valid_totals?(release_totals)
    @built_at = Time.iso8601(built_at.to_s).utc if built_at.present?
  rescue ArgumentError
    @built_at = nil
  end

  def short_revision = revision == 'unversioned' ? revision : revision.first(12)
  def label = "Build #{short_revision}"

  def self.current
    @current ||= load
  end

  def self.load(root: Rails.root, env: ENV)
    manifest = read_manifest(root)
    revision = [git_revision(root), env['RUPERT_BUILD_SHA'], manifest['revision']].find { |value| value.to_s.match?(REVISION) }
    totals = JSON.parse(File.read(root.join('config/release_metadata.json'))) if root.join('config/release_metadata.json').file?
    new(revision: revision, built_at: env['RUPERT_BUILT_AT'].presence || manifest['built_at'], release_totals: totals)
  rescue JSON::ParserError, Errno::ENOENT
    new(revision: revision, built_at: env['RUPERT_BUILT_AT'].presence || manifest['built_at'])
  end

  private

  def valid_totals?(totals)
    return false unless totals.is_a?(Hash) && totals['schema_version'] == 1 && totals['revision'] == revision
    return false unless totals['version'].is_a?(String) && totals['version'].match?(/\A\d+\.\d+\.\d+\z/)
    return false unless totals['base_revision'].nil? || totals['base_revision'].to_s.match?(REVISION)
    return false unless %w[nightly cumulative].all? do |scope|
      totals[scope].is_a?(Hash) && %w[patch_commits lines_added lines_deleted].all? do |key|
        totals[scope][key].is_a?(Integer) && totals[scope][key] >= 0
      end
    end
    return false unless totals.dig('nightly', 'confirmed_bugs_fixed').is_a?(Integer) && totals.dig('nightly', 'confirmed_bugs_fixed') >= 0
    return false unless totals['source_lines'].is_a?(Integer) && totals['source_lines'] >= 0

    Time.iso8601(totals.fetch('as_of')).utc
    true
  rescue ArgumentError, KeyError, TypeError
    false
  end

  public

  def self.read_manifest(root)
    value = JSON.parse(File.read(root.join('config/build.json')))
    value.is_a?(Hash) ? value : {}
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end
  private_class_method :read_manifest

  def self.git_revision(root)
    # Identify the actual booted checkout, even if old build variables remain.
    output, status = Open3.capture2e('git', '-c', "safe.directory=#{root.parent}", '-C', root.to_s, 'rev-parse', '--verify', 'HEAD')
    output.strip if status.success?
  rescue Errno::ENOENT
    nil
  end
  private_class_method :git_revision
end
