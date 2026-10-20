# frozen_string_literal: true

require 'test_helper'

class ModuleRegistryGroupsTest < ActiveSupport::TestCase
  test 'every grouped area lists each of its modules in exactly one group' do
    ModuleRegistry.singleton_class::AREAS.select { |area| area[:groups] }.each do |area|
      grouped = area[:groups].flat_map { |group| group[:modules] }
      assert_equal area[:modules].sort, grouped.sort, "#{area[:key]} groups must cover its modules exactly once"
    end
  end

  test 'groups_for keeps only visible modules and drops empty groups' do
    area = ModuleRegistry.singleton_class::AREAS.find { |a| a[:key] == 'money' }
    visible = ModuleRegistry.all.select { |entry| %w[bookkeeping reports].include?(entry.key) }
    groups = ModuleRegistry.groups_for(area, visible)
    assert_equal ['Overview', 'Reports & planning'], groups.map { |group| group[:name] }
    assert_equal ['bookkeeping'], groups.first[:modules].map(&:key)
  end
end
