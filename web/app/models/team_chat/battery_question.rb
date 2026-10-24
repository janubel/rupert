# frozen_string_literal: true

module TeamChat
  # A workspace's own test question: a new one, an edited copy of a built-in one (same question_id), or a removed
  # built-in one (status removed). TeamChat::Battery.items lays these over the built-in YAML set, so people who
  # know the books can tune the questions that score the bots without a code change.
  class BatteryQuestion < ApplicationRecord
    include TenantScoped

    self.table_name = 'chat_battery_questions'
    STATUSES = %w[active removed].freeze
    CADENCES = %w[daily weekly monthly sales comparison money_out tax books honesty cross].freeze
    ID = /\A[a-z][a-z0-9_-]{0,19}\z/

    belongs_to :updated_by, class_name: 'User', optional: true
    serialize :checks_json, coder: JSON
    serialize :needs_json, coder: JSON

    validates :set_name, presence: true, format: { with: /\A[a-z0-9_]+\z/ }
    validates :question_id, presence: true, format: { with: ID, message: 'is 1-20 lowercase letters, digits, _ or -, starting with a letter' }
    validates :question_id, uniqueness: { scope: %i[tenant_id set_name] }
    validates :status, inclusion: { in: STATUSES }
    validates :question, presence: true, length: { maximum: 500 }, if: :active?
    validates :expect, length: { maximum: 1000 }
    validates :cadence, presence: true, length: { maximum: 30 }, if: :active?
    validates :area, length: { maximum: 30 }
    validate :checks_are_read_only_tools

    def active? = status == 'active'
    def checks = Array(checks_json)
    def needs = Array(needs_json).map(&:to_s)

    def to_item
      Battery::Item.new(id: question_id, cadence: cadence, question: question.to_s.squish, checks: checks, expect: expect.to_s.squish.presence,
        module: area.presence, needs: needs)
    end

    private

    # Each check is a read-only Rupert tool name, or { tool:, args: {} }: the grader gets its output as the truth.
    def checks_are_read_only_tools
      return unless active?

      checks.each do |check|
        name = check.is_a?(Hash) ? (check['tool'] || check[:tool]).to_s : check.to_s
        tool = Mcp::Registry.find(name)
        errors.add(:checks, "#{name.first(40).inspect} is not a read-only Rupert tool") unless tool&.read_only
        args = check.is_a?(Hash) ? (check['args'] || check[:args]) : nil
        errors.add(:checks, "for #{name} must be a list of argument names and values") if args && !args.is_a?(Hash)
      end
      errors.add(:checks, 'can name at most 3 tools') if checks.size > 3
    end
  end
end
