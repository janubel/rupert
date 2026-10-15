# frozen_string_literal: true

require 'test_helper'

class OwnerChecklistPrivacyTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'private owner form containers are filtered before logs can expose nested contacts or evidence' do
    fields = {
      'owner_checklist' => { 'owner_email' => 'private-owner@example.invalid', 'notes' => 'private business notes' },
      'owner_service' => { 'support_phone' => 'private contact', 'login_url' => 'https://private.example.com/login' },
      'owner_feature' => { 'evidence' => 'private test findings', 'tested_on' => '2026-10-15' },
      'feature_id' => 'F50'
    }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(fields)
    %w[owner_checklist owner_service owner_feature].each { |key| assert_equal '[FILTERED]', filtered.fetch(key) }
    assert_equal 'F50', filtered.fetch('feature_id')
    assert_not_includes filtered.inspect, 'private'
  end

  test 'owner checklist navigation stays limited to active administrators despite broad staff overrides' do
    owner = users(:regular_user)
    assert owner.admin?
    assert_includes ModuleRegistry.nav_for(owner).map(&:key), 'owner_checklists'
    owner.active = false
    assert_not_includes ModuleRegistry.nav_for(owner).map(&:key), 'owner_checklists'
    staff = User.create!(tenant: Current.tenant, role: 'manager', email: 'checklist-staff@example.invalid', password: 'password123')
    staff.update_permission_overrides!(%w[settings.read settings.write owner_checklists.manage])
    assert_not_includes ModuleRegistry.nav_for(staff).map(&:key), 'owner_checklists'
    assert_equal 'system', ModuleRegistry.area_key_for('owner_checklists')
  end
end
