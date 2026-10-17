# frozen_string_literal: true

require 'test_helper'

class BuildVersionTest < ActionDispatch::IntegrationTest
  setup { BuildInfo.stubs(:current).returns(BuildInfo.new(revision: 'd' * 40)) }

  test 'signed-out pages always identify their build visibly and over HTTP' do
    get login_path
    assert_response :success
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
    assert_select '[aria-label="Rupert build version"][data-build-version=?]', 'd' * 40, count: 1
    assert_includes response.body, "Build #{'d' * 12}"
  end

  test 'health and redirect responses include build identity without needing a layout' do
    get '/up'
    assert_response :success
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
    get books_desk_path
    assert_response :redirect
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
  end
end
