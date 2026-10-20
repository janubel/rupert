# frozen_string_literal: true

require 'test_helper'

class PageToursTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @employee = User.create!(email: 'tour-staff@example.com', password: 'password123', role: 'employee',
      tenant_id: 'test-tenant-default', name: 'Tour Staff')
  end

  teardown { Current.reset }

  test 'every tour opens a routed page' do
    PageTours.all.each do |tour|
      path = tour.path
      next if path == '/'

      route = begin
        Rails.application.routes.recognize_path(path, method: :get)
      rescue ActionController::RoutingError
        nil
      end
      assert route&.dig(:controller).present?, "#{tour.key} path #{path} is not routed"
    end
  end

  test 'every step has an anchor, a title and a body, and anchors are unique within a tour' do
    PageTours.all.each do |tour|
      assert tour.steps.any?, "#{tour.key} has no steps"
      tour.steps.each do |step|
        %i[anchor title body].each do |field|
          assert step[field].present?, "#{tour.key} step is missing #{field}: #{step.inspect}"
        end
      end
      anchors = tour.steps.map { |step| step[:anchor] }
      assert_equal anchors.uniq, anchors, "#{tour.key} repeats an anchor"
    end
  end

  test 'tour keys are unique and every tour names a path' do
    keys = PageTours.all.map(&:key)
    assert_equal keys.uniq, keys
    assert PageTours.all.all? { |tour| tour.paths.present? }
  end

  test 'staff accounts only see the tours for pages they can open' do
    keys = PageTours.available(@employee).map(&:key)
    assert_includes keys, 'employee_home'
    assert_includes keys, 'learning'
    assert_includes keys, 'tasks'
    assert_includes keys, 'ctrax_pos', 'employees hold pos.use so the register tour is theirs'
    assert_empty keys - %w[employee_home learning tasks ctrax_pos]
  end

  test 'admins see the permission-gated tours' do
    keys = PageTours.available(@admin).map(&:key)
    %w[dashboard sales customers sync connections timesheets employees receipts tasks users books_desk reports].each do |key|
      assert_includes keys, key
    end
  end

  test 'for_path matches by prefix and picks the most specific tour' do
    assert_equal 'sales', PageTours.for_path('/sales/anything', @admin)&.key
    assert_equal 'tasks', PageTours.for_path('/projects/tasks', @admin)&.key
    assert_equal 'reports', PageTours.for_path('/reports/sales', @admin)&.key
    assert_equal 'dashboard', PageTours.for_path('/', @admin)&.key
    assert_nil PageTours.for_path('/salesx', @admin)
    assert_nil PageTours.for_path('/sales', @employee), 'staff cannot take the sales tour'
  end
end
