# frozen_string_literal: true

require 'test_helper'

class PageLayoutHelperTest < ActionView::TestCase
  test 'renders eyebrow, h1 and subtitle in one header' do
    html = page_header('Edit goal', subtitle: 'Targets for the month.', eyebrow: 'Goals')
    assert_select Nokogiri::HTML.fragment(html), 'header.page-header' do
      assert_select 'p.eyebrow', 'Goals'
      assert_select 'h1.page-title', 'Edit goal'
      assert_select 'p.page-subtitle', 'Targets for the month.'
      assert_select '.page-header-actions', count: 0
    end
  end

  test 'omits optional parts and escapes the text once' do
    html = page_header('POS & payment connections')
    assert_includes html, '<h1 class="page-title">POS &amp; payment connections</h1>'
    assert_no_match(/eyebrow|page-subtitle/, html)
  end

  test 'a block becomes the actions area' do
    html = page_header('Customers') { link_to('Add customer', '/customers/new', class: 'btn-primary') }
    assert_select Nokogiri::HTML.fragment(html), '.page-header-actions a.btn-primary[href="/customers/new"]', 'Add customer'
  end

  test 'sets the tab title from the header unless the view already did' do
    page_header('From header')
    assert_equal 'From header', content_for(:title)
    page_header('Ignored')
    assert_equal 'From header', content_for(:title)
  end
end
