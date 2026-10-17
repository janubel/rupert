# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class BuildInfoTest < ActiveSupport::TestCase
  test 'booted checkout wins over stale deployment environment' do
    Open3.stubs(:capture2e).returns(["#{'a' * 40}\n", stub(success?: true)])
    build = BuildInfo.load(env: { 'RUPERT_BUILD_SHA' => 'b' * 40 })
    assert_equal 'a' * 40, build.revision
    assert_equal "Build #{'a' * 12}", build.label
  end

  test 'git-free builds use their packaged revision and optional UTC timestamp' do
    Open3.stubs(:capture2e).raises(Errno::ENOENT)
    Dir.mktmpdir do |path|
      root = Pathname(path)
      root.join('config').mkpath
      root.join('config/build.json').write({ revision: 'c' * 40, built_at: '2026-10-17T12:00:00-04:00' }.to_json)
      build = BuildInfo.load(root: root, env: {})
      assert_equal 'c' * 40, build.revision
      assert_equal '2026-10-17T16:00:00Z', build.built_at.iso8601
      root.join('config/build.json').write('broken json')
      assert_equal 'unversioned', BuildInfo.load(root: root, env: {}).revision
    end
  end

  test 'invalid revision and timestamps never become response-header values' do
    build = BuildInfo.new(revision: "abc\r\nx-extra: injected", built_at: 'not a time')
    assert_equal 'unversioned', build.revision
    assert_nil build.built_at
  end
end
