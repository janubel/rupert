# frozen_string_literal: true

require 'test_helper'

# The account menu offers every appearance the stylesheet defines, and the
# first-paint script knows the same names, so a saved choice never dangles.
class AppearanceMenuTest < ActionDispatch::IntegrationTest
  THEMES = %w[herbal light mist sepia dark].freeze

  setup do
    tenant = tenants(:default_tenant)
    User.create!(email: 'looks@example.com', password: 'password123', role: 'admin', tenant_id: tenant.id, name: 'Looks')
    post login_path, params: { email: 'looks@example.com', password: 'password123' }
  end

  test 'the account menu lists the five appearances as radio items, Herbal first' do
    get dashboard_path
    assert_response :success
    THEMES.each do |theme|
      assert_select "button[role='menuitemradio'][data-theme-value='#{theme}']", 1
    end
    assert_select "meta[name='theme-color'][content='#e6efea']", 1, 'Herbal page color by default'
  end

  test 'the stylesheet defines a token set for every non-default appearance and the early script knows them' do
    css = File.read(Rails.root.join('app/assets/tailwind/application.css'))
    script = File.read(Rails.root.join('app/views/layouts/_theme.html.erb'))
    assert_includes css, '@theme {', 'Herbal is the @theme default'
    (THEMES - ['herbal']).each do |theme|
      assert_includes css, %(:root[data-theme="#{theme}"]), "#{theme} tokens"
      assert_includes script, %(#{theme}: "#), "#{theme} page color in the first-paint script"
    end
    assert_not_includes css, ':root:not([data-theme])', 'no appearance may claim the attribute-less default'
  end

  test 'the page color is the same in the stylesheet, the first-paint script and the picker for every appearance' do
    css = File.read(Rails.root.join('app/assets/tailwind/application.css'))
    script = File.read(Rails.root.join('app/views/layouts/_theme.html.erb'))
    picker = File.read(Rails.root.join('app/javascript/controllers/theme_controller.js'))
    expected = { 'herbal' => css[/@theme \{.*?--color-oat:\s*(#\h{6})/m, 1] }
    (THEMES - ['herbal']).each do |theme|
      expected[theme] = css[/:root\[data-theme="#{theme}"\]\s*\{.*?--color-oat:\s*(#\h{6})/m, 1]
    end
    expected.each do |theme, color|
      assert color, "#{theme} defines --color-oat"
      assert_includes script, %(#{theme}: "#{color}") unless theme == 'herbal'
      assert_includes picker, %(#{theme}: "#{color}")
    end
    assert_includes response_layout_colors, expected['herbal'], 'layouts ship the Herbal default as theme-color'
  end

  private

  def response_layout_colors
    %w[application employee].map { |name| File.read(Rails.root.join("app/views/layouts/#{name}.html.erb"))[/theme-color" content="(#\h{6})"/, 1] }.uniq.join(' ')
  end
end
