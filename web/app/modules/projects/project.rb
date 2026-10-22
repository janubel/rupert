# frozen_string_literal: true

module Projects
  class Project < ApplicationRecord
    include TenantScoped
    include ProjectsPeople
    include AASM

    self.table_name = 'projects'

    belongs_to :owner, class_name: 'User', foreign_key: :owner_id, optional: true
    belongs_to :goal, class_name: 'Goals::Goal', optional: true
    has_many :tasks, class_name: 'Projects::Task', foreign_key: :project_id, inverse_of: :project, dependent: :destroy
    has_many :project_members, class_name: 'Projects::ProjectMember', foreign_key: :project_id, inverse_of: :project, dependent: :destroy
    has_many :members, through: :project_members, source: :user

    validates :name, presence: true, length: { maximum: 120 }
    validate { validate_project_person(:owner_id) }
    validate :goal_belongs_to_tenant
    validate :dates_in_order

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }
    scope :search, lambda { |term|
      like = "%#{sanitize_sql_like(term.to_s.strip.downcase)}%"
      where('LOWER(projects.name) LIKE :q OR LOWER(COALESCE(projects.description, \'\')) LIKE :q', q: like)
    }

    aasm column: 'status', no_direct_assignment: true do
      state :planned, initial: true
      state :active
      state :on_hold
      state :completed
      state :archived

      event :start do
        transitions from: %i[planned on_hold], to: :active
      end
      event :hold do
        transitions from: :active, to: :on_hold
      end
      event :complete do
        transitions from: %i[active on_hold], to: :completed
      end
      event :archive do
        transitions from: %i[completed planned active on_hold], to: :archived
      end
      event :reopen do
        transitions from: %i[completed archived], to: :active
      end
    end

    # { 'todo' => 2, 'in_progress' => 1, ... } from one grouped query, memoized
    # so cards and bars on the same page do not re-count.
    def task_counts
      @task_counts ||= Projects::Task::BOARD_STATUSES.index_with(0).merge(tasks.group(:status).count)
    end

    # Lets the index fill the stats for a whole page in one grouped query.
    def preload_task_stats(counts, overdue)
      @task_counts = counts
      @overdue_count = overdue
    end

    def task_total
      task_counts.values.sum
    end

    def overdue_count
      @overdue_count ||= tasks.overdue.count
    end

    def progress_pct
      return 0 if task_total.zero?

      (task_counts['done'].to_f / task_total * 100).round
    end

    # :empty, :done, :at_risk (overdue work or blocked tasks), :on_track, :idle
    def health
      return :empty if task_total.zero?
      return :done if completed? || task_counts['done'] == task_total
      return :at_risk if overdue_count.positive? || task_counts['blocked'].positive? || (due_on && due_on < Date.current)
      return :on_track if task_counts['in_progress'].positive? || task_counts['done'].positive?

      :idle
    end

    def days_left
      (due_on - Date.current).to_i if due_on
    end

    def unfinished_count
      task_total - task_counts['done'].to_i
    end

    # The owner and members: the people who hear about activity on the project.
    def team_ids
      ([owner_id] + project_members.pluck(:user_id).map(&:to_s)).compact_blank.uniq
    end

    def logged_minutes
      Projects::TaskTimeEntry.where(task_id: tasks.select(:id)).sum(:minutes)
    end

    def estimated_minutes
      tasks.sum(:estimate_minutes)
    end

    # First and last day shown on the timeline: the project's own dates and every task's.
    def timeline_range
      days = [start_on, due_on, *tasks.pluck(:start_on, :due_on).flatten].compact
      return if days.empty?

      [days.min, [days.max, days.min + 6].max]
    end

    private

    def goal_belongs_to_tenant
      return if goal_id.blank?
      return if Goals::Goal.unscoped.exists?(id: goal_id, tenant_id: tenant_id || Current.tenant_id)

      errors.add(:goal, 'was not found')
    end

    def dates_in_order
      errors.add(:due_on, 'cannot be before the start date') if start_on && due_on && due_on < start_on
    end
  end
end
