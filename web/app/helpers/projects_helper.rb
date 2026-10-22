# frozen_string_literal: true

# Shared look for the Projects and Tasks screens: one place for status colors,
# priority marks and project health.
module ProjectsHelper
  # Options for a person picker. selected is one id or a list; a selected person who
  # has since been deactivated stays listed so saving does not silently drop them.
  def project_person_options(selected = nil)
    @project_people ||= Projects::Task.available_people.to_a
    chosen = Array(selected).map(&:to_s).compact_blank
    options = @project_people.map { |person| [person.display_name, person.id.to_s] }
    missing = chosen - options.map(&:last)
    User.where(tenant_id: Current.tenant_id, id: missing).each { |person| options << ["#{person.display_name} (inactive)", person.id.to_s] }
    options_for_select(options, chosen)
  end

  STATUS_LABELS = {
    'todo' => 'To do', 'in_progress' => 'In progress', 'blocked' => 'Blocked', 'done' => 'Done',
    'planned' => 'Planned', 'active' => 'Active', 'on_hold' => 'On hold', 'completed' => 'Completed',
    'archived' => 'Archived'
  }.freeze

  # Segment colors of the progress bar and column accents, by task status.
  STATUS_BAR = {
    'done' => 'bg-fern', 'in_progress' => 'bg-olive', 'blocked' => 'bg-rose', 'todo' => 'bg-fog'
  }.freeze

  PRIORITY_DOT = {
    'urgent' => 'bg-rose', 'high' => 'bg-clay', 'medium' => 'bg-olive', 'low' => 'bg-taupe/50'
  }.freeze

  def status_label(status)
    STATUS_LABELS.fetch(status.to_s) { status.to_s.humanize }
  end

  def project_status_pill(project)
    css =
      if project.completed? then 'pill-fern'
      elsif project.archived? then 'pill-taupe'
      elsif project.active? then 'pill-olive'
      else 'pill-clay'
      end
    tag.span(status_label(project.status), class: css)
  end

  def task_status_pill(task)
    css =
      if task.done? then 'pill-fern'
      elsif task.blocked? then 'pill-rose'
      elsif task.in_progress? then 'pill-olive'
      else 'pill-taupe'
      end
    tag.span(status_label(task.status), class: css)
  end

  def priority_dot(priority)
    tag.span('', class: "inline-block h-2 w-2 shrink-0 rounded-full #{PRIORITY_DOT.fetch(priority.to_s, 'bg-olive')}",
      title: "#{priority.to_s.capitalize} priority", role: 'img', 'aria-label': "#{priority} priority")
  end

  HEALTH = {
    done: ['Complete', 'pill-fern'], at_risk: ['Needs attention', 'pill-rose'],
    on_track: ['On track', 'pill-olive'], idle: ['Not started', 'pill-taupe'], empty: ['No tasks', 'pill-taupe']
  }.freeze

  def project_health_pill(project)
    label, css = HEALTH.fetch(project.health)
    tag.span(label, class: css)
  end

  def due_class(task)
    if task.overdue? then 'font-semibold text-rose'
    elsif task.due_today? then 'font-semibold text-clay'
    else 'text-taupe'
    end
  end

  # 90 -> "1h 30m", 45 -> "45m", 120 -> "2h".
  def duration_label(minutes)
    minutes = minutes.to_i
    return '0m' if minutes.zero?

    hours, rest = minutes.divmod(60)
    [("#{hours}h" if hours.positive?), ("#{rest}m" if rest.positive?)].compact.join(' ')
  end

  def label_chips(task)
    safe_join(Array(task.labels).map { |label| link_to(label, tasks_filter_path(label: label), class: 'rounded-full bg-haze px-2 py-0.5 text-[11px] font-medium text-mocha hover:text-ink') }, ' ')
  end

  def recurrence_label(task)
    Projects::Task::RECURRENCES[task.recurrence]
  end

  def initials(name)
    name.to_s.split.first(2).map { |w| w[0] }.join.upcase.presence || '?'
  end

  # Tasks index URL that keeps the current filters, with overrides applied.
  # A nil override removes that filter.
  def tasks_filter_path(**overrides)
    current = params.permit(:q, :priority, :project_id, :mine, :due, :status, :view, :label, :month).to_h.symbolize_keys
    projects_tasks_path(current.merge(overrides).compact_blank)
  end

  def tasks_export_path
    current = params.permit(:q, :priority, :project_id, :mine, :due, :status, :label).to_h.symbolize_keys
    export_projects_tasks_path(current.compact_blank)
  end

  def tasks_filtered?
    %i[q priority project_id mine due status label].any? { |key| params[key].present? }
  end
end
