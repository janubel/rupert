# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'tmpdir'

class LocalEnvironmentTest < ActiveSupport::TestCase
  test 'test startup never loads credentials from the repository env file' do
    values = boot_with_local_env('test')
    assert_nil values['sentinel']
    assert_nil values['host']
  end

  test 'development startup loads the repository env after the bundle is configured' do
    values = boot_with_local_env('development')
    assert_equal 'local-example', values['sentinel']
    assert_equal 'https://local.example', values['host']
  end

  test 'process configuration takes precedence over the local env file' do
    values = boot_with_local_env('development', host: 'http://localhost:3000')
    assert_equal 'http://localhost:3000', values['host']
  end

  private

  def boot_with_local_env(environment, host: nil)
    Dir.mktmpdir('rupert-boot-') do |root|
      config = File.join(root, 'web', 'config')
      FileUtils.mkdir_p(config)
      %w[application.rb boot.rb shopify_api_version.rb].each { |name| FileUtils.cp(Rails.root.join('config', name), config) }
      File.write(File.join(root, '.env'), "RUPERT_BOOT_TEST_SENTINEL=local-example\nHOST=local.example\n")
      script = "require #{File.join(config, 'application.rb').inspect}; puts({ sentinel: ENV['RUPERT_BOOT_TEST_SENTINEL'], host: ENV['HOST'] }.to_json)"
      env = { 'RAILS_ENV' => environment, 'RACK_ENV' => nil, 'HOST' => host, 'RUPERT_BOOT_TEST_SENTINEL' => nil,
        'BUNDLE_GEMFILE' => Rails.root.join('Gemfile').to_s, 'BOOTSNAP_CACHE_DIR' => File.join(root, 'cache') }
      output, error, status = Open3.capture3(env, RbConfig.ruby, '-e', script)
      assert status.success?, error
      JSON.parse(output)
    end
  end
end
