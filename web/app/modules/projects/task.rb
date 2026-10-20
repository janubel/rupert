# frozen_string_literal: true

module Projects
  class Task < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'tasks'

    PRIORITIES = %w[low medium high urgent].freeze
    PRIORITY_RANK = { 'urgent' => 0, 'high' => 1, 'medium' => 2, 'low' => 3 }.freeze
    # Board columns, left to right.
    BOARD_STATUSES = %w[todo in_progress blocked done].freeze

    belongs_to :project, class_name: 'Projects::Project', foreign_key: :project_id, optional: true
    belongs_to :assignee, class_name: 'User', foreign_key: :assignee_id, optional: true

    validates :title, presence: true
    validates :priority, inclusion: { in: PRIORITIES }
    validate :project_belongs_to_tenant

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }
    scope :open, -> { where(status: %w[todo in_progress]) }
    scope :completed, -> { where(status: 'done') }
    scope :overdue, -> { where.not(status: 'done').where('due_on < ?', Date.current) }
    scope :due_within, ->(days) { where.not(status: 'done').where(due_on: Date.current..(Date.current + days)) }
    scope :assigned_to, ->(user_id) { where(assignee_id: user_id.to_s) }
    scope :search, lambda { |term|
      like = "%#{sanitize_sql_like(term.to_s.strip.downcase)}%"
      where('LOWER(tasks.title) LIKE :q OR LOWER(COALESCE(tasks.description, \'\')) LIKE :q', q: like)
    }
    # Urgent first, then soonest due, undated last.
    scope :by_priority, lambda {
      order(Arel.sql("CASE tasks.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END"),
        Arel.sql('CASE WHEN tasks.due_on IS NULL THEN 1 ELSE 0 END'), :due_on, :id)
    }

    aasm column: 'status', no_direct_assignment: true do
      state :todo, initial: true
      state :in_progress
      state :done
      state :blocked

      event :start do
        transitions from: %i[todo blocked done], to: :in_progress
        before { self.completed_at = nil }
      end
      event :unstart do
        transitions from: :in_progress, to: :todo
      end
      event :finish do
        transitions from: %i[in_progress todo blocked], to: :done
        before { self.completed_at = Time.current }
      end
      event :block do
        transitions from: %i[todo in_progress done], to: :blocked
        before { self.completed_at = nil }
      end
      event :reopen do
        transitions from: %i[done blocked], to: :todo
        before { self.completed_at = nil }
      end
    end

    # Moves the task to a board column through its state machine. Returns
    # false when the task is already there or the move is not allowed.
    def move_to!(target)
      return false if target == status || BOARD_STATUSES.exclude?(target)

      event = case target
              when 'in_progress' then :start
              when 'done' then :finish
              when 'blocked' then :block
              else in_progress? ? :unstart : :reopen
              end
      return false unless public_send(:"may_#{event}?")

      public_send(:"#{event}!")
      true
    end

    def overdue?
      due_on.present? && due_on < Date.current && !done?
    end

    def due_today?
      due_on == Date.current && !done?
    end

    # Short human label: "Overdue 3d", "Due today", "Due in 2d", "Jun 4".
    def due_label
      return if due_on.blank?

      days = (due_on - Date.current).to_i
      return "Overdue #{-days}d" if days.negative? && !done?
      return 'Due today' if days.zero? && !done?
      return "Due in #{days}d" if days.positive? && days <= 7 && !done?

      due_on.strftime('%b %-d')
    end

    private

    def project_belongs_to_tenant
      return if project_id.blank?
      return unless new_record? || project_id_changed?
      return if Projects::Project.unscoped.exists?(id: project_id, tenant_id: tenant_id || Current.tenant_id)

      errors.add(:project, 'was not found')
    end
  end
end
