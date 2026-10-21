# frozen_string_literal: true

require 'test_helper'

class LegacyHostRedirectTest < ActiveSupport::TestCase
  APP = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['app']] }

  def middleware(legacy: 'rupert.stoverparc.org, Herbalhealers.Cybersecuritypilot.org', canonical: 'https://herbalhealers.rupertpos.com')
    LegacyHostRedirect.new(APP, legacy: legacy, canonical: canonical)
  end

  def call(app, url, method: 'GET')
    app.call(Rack::MockRequest.env_for(url, method: method))
  end

  test 'retired hosts move to the canonical origin with path and query' do
    status, headers, = call(middleware, 'https://rupert.stoverparc.org/syncs?tab=square#x')
    assert_equal 301, status
    assert_equal 'https://herbalhealers.rupertpos.com/syncs?tab=square', headers['location']

    status, headers, = call(middleware, 'https://herbalhealers.cybersecuritypilot.org/login', method: 'POST')
    assert_equal 308, status
    assert_equal 'https://herbalhealers.rupertpos.com/login', headers['location']
  end

  test 'the canonical host, other hosts and health checks are served normally' do
    assert_equal 200, call(middleware, 'https://herbalhealers.rupertpos.com/syncs').first
    assert_equal 200, call(middleware, 'https://pos.rupertpos.com/').first
    assert_equal 200, call(middleware, 'https://rupert.stoverparc.org/up').first
    assert_equal 200, call(middleware, 'https://rupert.stoverparc.org/up/ready').first
  end

  test 'does nothing without a list or a usable canonical origin, and never loops' do
    assert_equal 200, call(middleware(legacy: ''), 'https://rupert.stoverparc.org/').first
    assert_equal 200, call(middleware(canonical: ''), 'https://rupert.stoverparc.org/').first
    assert_equal 200, call(middleware(canonical: 'not a url'), 'https://rupert.stoverparc.org/').first
    assert_equal 200, call(middleware(legacy: 'herbalhealers.rupertpos.com'), 'https://herbalhealers.rupertpos.com/').first
  end

  test 'keeps a non-default port on the canonical origin' do
    _, headers, = call(middleware(canonical: 'http://localhost:3000'), 'http://rupert.stoverparc.org/a')
    assert_equal 'http://localhost:3000/a', headers['location']
  end
end
