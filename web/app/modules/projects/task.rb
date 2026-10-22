# frozen_string_literal: true

module Projects
  class Task < ApplicationRecord
    include TenantScoped
    include ProjectsPeople
    include AASM

    self.table_name = 'tasks'

    PRIORITIES = %w[low medium high urgent].freeze
    PRIORITY_RANK = { 'urgent' => 0, 'high' => 1, 'medium' => 2, 'low' => 3 }.freeze
    # Board columns, left to right.
    BOARD_STATUSES = %w[todo in_progress blocked done].freeze
    RECURRENCES = {
      'daily' => 'Every day', 'weekly' => 'Every week', 'biweekly' => 'Every 2 weeks', 'monthly' => 'Every month', 'yearly' => 'Every year'
    }.freeze
    LABEL_LIMIT = 10
    LABEL_LENGTH = 30

    belongs_to :project, class_name: 'Projects::Project', foreign_key: :project_id, optional: true
    belongs_to :assignee, class_name: 'User', foreign_key: :assignee_id, optional: true
    has_many :comments, -> { order(:created_at, :id) }, class_name: 'Projects::TaskComment', foreign_key: :task_id, inverse_of: :task, dependent: :destroy
    has_many :checklist_items, -> { order(:position, :id) }, class_name: 'Projects::TaskChecklistItem', foreign_key: :task_id, inverse_of: :task, dependent: :destroy
    has_many :time_entries, -> { order(logged_on: :desc, id: :desc) }, class_name: 'Projects::TaskTimeEntry', foreign_key: :task_id, inverse_of: :task, dependent: :destroy
    has_many :attachments, -> { order(:created_at, :id) }, class_name: 'Projects::TaskAttachment', foreign_key: :task_id, inverse_of: :task, dependent: :destroy
    has_many :dependencies, class_name: 'Projects::TaskDependency', foreign_key: :task_id, inverse_of: :task, dependent: :destroy
    has_many :dependents, class_name: 'Projects::TaskDependency', foreign_key: :blocker_id, dependent: :destroy
    has_many :blockers, through: :dependencies, source: :blocker

    attribute :labels, :json, default: -> { [] }

    # Rows written before labels existed hold NULL.
    def labels = super || []

    validates :title, presence: true, length: { maximum: 200 }
    validates :priority, inclusion: { in: PRIORITIES }
    validates :recurrence, inclusion: { in: RECURRENCES.keys }, allow_blank: true
    validates :estimate_minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100_000 }, allow_nil: true
    validates :blocked_reason, length: { maximum: 1000 }
    validate :project_belongs_to_tenant
    validate :dates_in_order
    validate :labels_within_limits
    validate { validate_project_person(:assignee_id) }

    before_validation :normalize_labels
    before_validation { self.recurrence = nil if recurrence.blank? }

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }
    scope :open, -> { where(status: %w[todo in_progress]) }
    scope :unfinished, -> { where.not(status: 'done') }
    scope :completed, -> { where(status: 'done') }
    scope :overdue, -> { where.not(status: 'done').where('due_on < ?', Date.current) }
    scope :due_within, ->(days) { where.not(status: 'done').where(due_on: Date.current..(Date.current + days)) }
    scope :assigned_to, ->(user_id) { where(assignee_id: user_id.to_s) }
    scope :search, lambda { |term|
      like = "%#{sanitize_sql_like(term.to_s.strip.downcase)}%"
      where('LOWER(tasks.title) LIKE :q OR LOWER(COALESCE(tasks.description, \'\')) LIKE :q', q: like)
    }
    scope :with_label, ->(label) { where('tasks.labels LIKE ?', "%#{sanitize_sql_like(label.to_s.strip.to_json)}%") }
    # Urgent first, then soonest due, undated last.
    scope :by_priority, lambda {
      order(Arel.sql("CASE tasks.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END"),
        Arel.sql('CASE WHEN tasks.due_on IS NULL THEN 1 ELSE 0 END'), :due_on, :id)
    }
    # A hand-placed order wins; tasks nobody has placed follow by priority.
    scope :by_board_order, lambda {
      order(Arel.sql('CASE WHEN tasks.position IS NULL THEN 1 ELSE 0 END'), :position).by_priority
    }

    aasm column: 'status', no_direct_assignment: true do
      state :todo, initial: true
      state :in_progress
      state :done
      state :blocked

      event :start do
        transitions from: %i[todo blocked done], to: :in_progress, guard: :unblocked?
        before { clear_stop_state }
      end
      event :unstart do
        transitions from: :in_progress, to: :todo
      end
      event :finish do
        transitions from: %i[in_progress todo blocked], to: :done, guard: :unblocked?
        before do
          clear_stop_state
          self.completed_at = Time.current
        end
        after { after_finished }
      end
      event :block do
        transitions from: %i[todo in_progress done], to: :blocked
        before { self.completed_at = nil }
      end
      event :reopen do
        transitions from: %i[done blocked], to: :todo
        before { clear_stop_state }
      end
    end

    # Moves the task to a board column through its state machine. Returns
    # false when the task is already there or the move is not allowed.
    def move_to!(target)
      with_lock do
        next false if target == status || BOARD_STATUSES.exclude?(target)

        event = case target
                when 'in_progress' then :start
                when 'done' then :finish
                when 'blocked' then :block
                else in_progress? ? :unstart : :reopen
                end
        next false unless public_send(:"may_#{event}?")

        public_send(:"#{event}!")
        true
      end
    end

    # Marks the task blocked and records what is needed to continue.
    def block_with_reason!(reason)
      self.blocked_reason = reason.to_s.strip.first(1000).presence
      block!
    end

    # True once every task this one waits on is done.
    def unblocked?
      open_blockers.none?
    end

    def open_blockers
      blockers.where.not(status: 'done')
    end

    # Why an event was refused, in words for the person who tried it.
    def refusal_for(event)
      waiting = open_blockers.limit(3).pluck(:title)
      return "Waiting on #{waiting.to_sentence}." if waiting.any? && %w[start finish].include?(event.to_s)

      "Cannot #{event} a #{status.humanize.downcase} task."
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

    # Whole hours in forms ("1.5", "2h", "90m"); stored as minutes.
    def estimate_hours
      (estimate_minutes / 60.0).round(2).to_s.delete_suffix('.0') if estimate_minutes
    end

    def estimate_hours=(text)
      self.estimate_minutes = text.to_s.strip.empty? ? nil : (Projects::TaskTimeEntry.parse_minutes(text) || 0)
    end

    def labels_text
      Array(labels).join(', ')
    end

    def labels_text=(text)
      self.labels = text.to_s.split(/[,\n]/)
    end

    def logged_minutes
      time_entries.sum(:minutes)
    end

    def checklist_progress
      items = checklist_items.to_a
      [items.count(&:done), items.size]
    end

    private

    # Leaving the blocked or done state forgets why the task was stuck.
    def clear_stop_state
      self.completed_at = nil
      self.blocked_reason = nil
    end

    def after_finished
      spawn_next_occurrence
      notify_unblocked_dependents
    end

    def spawn_next_occurrence
      return if recurrence.blank? || next_spawned_at.present?

      due = next_recurrence_date(due_on || Date.current)
      shift = due_on ? (due - due_on).to_i : 0
      copy = self.class.new(
        project_id: project_id, title: title, description: description, priority: priority, labels: labels, recurrence: recurrence,
        estimate_minutes: estimate_minutes, due_on: due, start_on: (start_on + shift if start_on),
        assignee_id: (assignee_id if User.where(tenant_id: tenant_id).active.exists?(id: assignee_id))
      )
      checklist_items.each { |item| copy.checklist_items.build(title: item.title) }
      return unless copy.save

      update_columns(next_spawned_at: Time.current)
      Notification.deliver(copy.assignee_id, kind: 'task_recurred', title: "Due again: #{copy.title}", body: copy.due_label,
        url: Rails.application.routes.url_helpers.projects_task_path(copy), actor: nil)
    end

    # One interval on, then forward until it is not already in the past.
    def next_recurrence_date(from)
      step = { 'daily' => 1.day, 'weekly' => 1.week, 'biweekly' => 2.weeks, 'monthly' => 1.month, 'yearly' => 1.year }.fetch(recurrence)
      date = from + step
      date += step while date < Date.current
      date
    end

    def notify_unblocked_dependents
      dependents.includes(:task).each do |link|
        waiting = link.task
        next unless waiting && !waiting.done? && waiting.unblocked?

        Notification.deliver(waiting.assignee_id, kind: 'task_unblocked', title: "Ready to start: #{waiting.title}",
          body: "“#{title}” is done.", url: Rails.application.routes.url_helpers.projects_task_path(waiting))
      end
    end

    def normalize_labels
      list = Array(labels).filter_map { |label| label.to_s.squish.presence }
      self.labels = list.uniq(&:downcase)
    end

    def labels_within_limits
      list = Array(labels)
      errors.add(:labels, "can have at most #{LABEL_LIMIT}") if list.size > LABEL_LIMIT
      errors.add(:labels, "must be #{LABEL_LENGTH} characters or fewer each") if list.any? { |label| label.length > LABEL_LENGTH }
    end

    def dates_in_order
      errors.add(:due_on, 'cannot be before the start date') if start_on && due_on && due_on < start_on
    end

    def project_belongs_to_tenant
      return if project_id.blank?
      return if Projects::Project.unscoped.exists?(id: project_id, tenant_id: tenant_id || Current.tenant_id)

      errors.add(:project, 'was not found')
    end
  end
end
