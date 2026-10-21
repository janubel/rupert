# frozen_string_literal: true

require 'test_helper'
require 'erb'
require 'yaml'

class SqliteOnlyDatabaseConfigTest < ActiveSupport::TestCase
  CONFIG_PATH = Rails.root.join('config/database.yml')
  DATABASE_ENV = %w[
    RUPERT_DB_ADAPTER DATABASE_URL
    RUPERT_SQLITE_DATABASE_DEVELOPMENT RUPERT_SQLITE_DATABASE_TEST RUPERT_SQLITE_DATABASE_PRODUCTION
  ].freeze

  test 'defaults every environment to SQLite and keeps tests on their own database file' do
    config = render_config

    %w[development test production].each do |environment|
      assert_equal 'sqlite3', config.fetch(environment).fetch('adapter')
      assert_equal 'schema.rb', config.fetch(environment).fetch('schema_dump')
    end
    assert_equal 'storage/test.sqlite3', config.fetch('test').fetch('database')
  end

  test 'production database path does not affect the test database file' do
    config = render_config('RUPERT_SQLITE_DATABASE_PRODUCTION' => '/synthetic/production.sqlite3')

    assert_equal '/synthetic/production.sqlite3', config.fetch('production').fetch('database')
    assert_equal 'storage/test.sqlite3', config.fetch('test').fetch('database')
  end

  test 'rejects the removed PostgreSQL adapter selector' do
    error = assert_raises(RuntimeError) { render_config('RUPERT_DB_ADAPTER' => 'postgresql') }

    assert_match(/SQLite only/, error.message)
  end

  test 'rejects a non-SQLite database URL' do
    error = assert_raises(RuntimeError) { render_config('DATABASE_URL' => 'postgres://example.invalid/rupert') }

    assert_match(/unset DATABASE_URL/, error.message)
  end

  test 'rejects even a SQLite URL so per-environment paths stay authoritative' do
    error = assert_raises(RuntimeError) { render_config('DATABASE_URL' => 'sqlite3:/tmp/alternate.sqlite3') }

    assert_match(/unset DATABASE_URL/, error.message)
  end

  private

  def render_config(overrides = {})
    with_database_environment(overrides) do
      YAML.safe_load(ERB.new(File.read(CONFIG_PATH)).result, aliases: true)
    end
  end

  def with_database_environment(overrides)
    keys = DATABASE_ENV | overrides.keys
    original = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    overrides.each { |key, value| ENV[key] = value unless value.nil? }
    yield
  ensure
    original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
