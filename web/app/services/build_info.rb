# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

# Immutable identity of the source loaded when this process started.
class BuildInfo
  REVISION = /\A[0-9a-f]{40,64}\z/i
  attr_reader :revision, :built_at

  def initialize(revision:, built_at: nil)
    @revision = revision.to_s.match?(REVISION) ? revision.downcase.freeze : 'unversioned'
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
    new(revision: revision, built_at: env['RUPERT_BUILT_AT'].presence || manifest['built_at'])
  end

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
