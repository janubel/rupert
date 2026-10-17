# frozen_string_literal: true

require 'test_helper'

class BrowserSessionTest < ActionController::TestCase
  tests SessionsController

  teardown { Current.reset }

  test 'legacy administrator cookies cannot redirect the login page back into the old account' do
    owner = users(:regular_user)
    owner.update!(role: 'super_admin')
    @request.session[:user_id] = owner.id
    @request.session[:auth_method] = 'google'
    get :new
    assert_response :success
    assert_nil session[:user_id]
    assert_nil Current.user
  end
end
