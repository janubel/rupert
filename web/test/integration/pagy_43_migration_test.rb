# frozen_string_literal: true

require 'test_helper'

class Pagy43MigrationTest < ActionDispatch::IntegrationTest
  test 'array-backed customer pagination renders links and redirects stale pages with filters' do
    Current.tenant = tenants(:default_tenant)
    Array.new(126) do |number|
      Core::Customer.create!(source: 'manual', external_id: "pagy-migration-#{number}", first_name: "Pagy Customer #{number}")
    end
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    filters = { q: { first_name_cont: 'Pagy Customer' } }
    get customers_path, params: filters

    assert_response :success
    assert_select 'tbody td:first-child a', count: 25
    assert_select 'nav.pagy.series-nav'
    nav_links = css_select('nav.pagy.series-nav a').filter_map { |link| CGI.unescapeHTML(link['href']) if link['href'] }
    assert nav_links.any? { |href| href.include?('first_name_cont') }, 'pagination links should preserve active search filters'

    get customers_path, params: filters.merge(page: 6)
    assert_response :success
    assert_select 'tbody td:first-child a', count: 1
    assert_select 'nav.pagy.series-nav [aria-current="page"]', text: '6'

    get customers_path, params: filters.merge(page: 999)
    assert_response :success
    assert_select 'tbody td:first-child a', count: 1
    assert_select 'nav.pagy.series-nav [aria-current="page"]', text: '6'
  ensure
    Current.reset
  end

  test 'a malformed page value falls back to the first page' do
    Current.tenant = tenants(:default_tenant)
    Core::Customer.create!(source: 'manual', external_id: 'pagy-malformed-page', first_name: 'Pagy Malformed Page')
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    get customers_path, params: { q: { first_name_cont: 'Pagy Malformed Page' }, page: 'not-a-page' }

    assert_response :success
    assert_select 'tbody td:first-child a', count: 1
    assert_select 'nav.pagy.series-nav', false
  ensure
    Current.reset
  end
end
