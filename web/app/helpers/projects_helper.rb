# frozen_string_literal: true

# Shared look for the Projects and Tasks screens: one place for status colors,
# priority marks and project health.
module ProjectsHelper
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

  def initials(name)
    name.to_s.split.first(2).map { |w| w[0] }.join.upcase.presence || '?'
  end

  # Tasks index URL that keeps the current filters, with overrides applied.
  # A nil override removes that filter.
  def tasks_filter_path(**overrides)
    current = params.permit(:q, :priority, :project_id, :mine, :due, :status, :view).to_h.symbolize_keys
    projects_tasks_path(current.merge(overrides).compact_blank)
  end

  def tasks_filtered?
    %i[q priority project_id mine due status].any? { |key| params[key].present? }
  end
end
