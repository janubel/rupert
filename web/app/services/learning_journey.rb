# frozen_string_literal: true

# Personal learning preferences live alongside the user's other workspace preferences.
# Writes lock the user so answering a lesson cannot overwrite another learning update.
#
# Stored under dashboard_config:
#   learning_focus            chosen path key
#   learning_completed        lesson keys answered correctly
#   learning_completed_at     { lesson key => ISO8601 time }
#   learning_welcome_hidden   the getting-started card was hidden
#   learning_welcomed_at      the first-run welcome was finished or skipped
#   learning_tours            page tour keys finished or skipped
#   learning_checklist_done   getting-started items marked done by hand
class LearningJourney
  PATHS = [
    { key: 'setup', label: 'Set up my workspace', lessons: %w[start setup sync access] },
    { key: 'checkout', label: 'Serve customers', lessons: %w[start checkout sales customers] },
    { key: 'stock', label: 'Look after stock', lessons: %w[start stock counts alerts] },
    { key: 'books', label: 'Understand sales and close the books', lessons: %w[start sales books reports] },
    { key: 'manage', label: 'Run the team', lessons: %w[start timesheet_review receipts_review tasks] },
    { key: 'work', label: 'Organize projects and goals', lessons: %w[start tasks work] },
    { key: 'tasks', label: 'Find and update my tasks', lessons: %w[start tasks] },
    { key: 'staff', label: 'Manage my hours and receipts', lessons: %w[start staff tasks] },
    { key: 'explore', label: 'Just find my way around', lessons: %w[start] }
  ].freeze

  # Plain-language descriptions shown on the welcome screen's path cards.
  PATH_DESCRIPTIONS = {
    'setup' => 'Connect your sources, verify a read and check your first day.',
    'checkout' => 'Ring up sales, read receipts and keep customer records tidy.',
    'stock' => 'Read quantities, count shelves and act on restock advice.',
    'books' => 'Make sense of totals, reconcile evidence and close each day.',
    'manage' => 'Review hours and receipts and keep assigned work moving.',
    'work' => 'Plan projects, track tasks and measure progress.',
    'tasks' => 'See what is assigned to you and keep its status honest.',
    'staff' => 'Clock in, check your hours and send receipts for review.',
    'explore' => 'The two-minute tour of where things are and what to check first.'
  }.freeze

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def config
    user.dashboard_config_hash
  end

  def lessons
    @lessons ||= LearningCatalog.available(user)
  end

  def lesson(key)
    lessons.find { |lesson| lesson[:key] == key.to_s }
  end

  # A path is offered when its first real lesson and most of its lessons are
  # available to this account, so a staff account is never offered "Run the
  # team". The explore path (just the intro) is always available.
  def paths
    PATHS.select do |path|
      steps = path[:lessons] - ['start']
      next true if steps.empty?

      lesson(steps.first) && steps.count { |key| lesson(key) } * 2 > steps.size
    end
  end

  def path_description(path)
    PATH_DESCRIPTIONS.fetch(path[:key], '')
  end

  def focus
    paths.find { |path| path[:key] == config['learning_focus'] } || default_focus
  end

  def focus_chosen?
    config['learning_focus'].present?
  end

  def path_lessons(path = focus)
    path[:lessons].filter_map { |key| lesson(key) }
  end

  def completed
    Array(config['learning_completed']) & lessons.pluck(:key)
  end

  def completed?(key)
    completed.include?(key.to_s)
  end

  def completed_at(key)
    value = config.dig('learning_completed_at', key.to_s)
    value && Time.zone.parse(value)
  rescue ArgumentError
    nil
  end

  def next_lesson
    path_lessons.find { |lesson| !completed?(lesson[:key]) }
  end

  def path_progress(path = focus)
    steps = path_lessons(path)
    [steps.count { |lesson| completed?(lesson[:key]) }, steps.size]
  end

  def path_complete?(path = focus)
    done, total = path_progress(path)
    total.positive? && done == total
  end

  # Every path the person has finished, for the learning centre's module badges.
  def completed_paths
    paths.select { |path| path_complete?(path) }
  end

  def welcome?
    !config['learning_welcome_hidden'] && next_lesson.present?
  end

  # The first-run welcome shows until the person picks a path or skips it.
  def welcomed?
    config['learning_welcomed_at'].present? || config['learning_welcome_hidden'] == true
  end

  def tours_done
    Array(config['learning_tours']).map(&:to_s)
  end

  def tour_done?(key)
    tours_done.include?(key.to_s)
  end

  def checklist_done
    Array(config['learning_checklist_done']).map(&:to_s)
  end

  def checklist_hidden?
    config['learning_checklist_hidden'] == true
  end

  def choose!(key)
    return false unless paths.any? { |path| path[:key] == key }

    save!('learning_focus' => key, 'learning_welcome_hidden' => false,
      'learning_welcomed_at' => config['learning_welcomed_at'] || Time.current.iso8601)
    true
  end

  # Finishing or skipping the welcome records a time; it never changes permissions.
  def welcome!
    save!('learning_welcomed_at' => Time.current.iso8601)
  end

  def dismiss!
    save!('learning_welcome_hidden' => true)
  end

  def hide_checklist!
    save!('learning_checklist_hidden' => true)
  end

  def show_checklist!
    save!('learning_checklist_hidden' => false, 'learning_welcome_hidden' => false)
  end

  def complete!(key)
    raise ArgumentError, 'Unavailable lesson' unless lesson(key)

    user.with_lock do
      config = user.dashboard_config_hash
      stamps = (config['learning_completed_at'].is_a?(Hash) ? config['learning_completed_at'] : {})
      stamps = stamps.merge(key => Time.current.iso8601) unless stamps.key?(key)
      user.update!(dashboard_config: config.merge('learning_completed' => (Array(config['learning_completed']) | [key]),
        'learning_completed_at' => stamps))
    end
  end

  def complete_tour!(key)
    key = key.to_s
    raise ArgumentError, 'Unknown tour' unless PageTours.permitted?(PageTours.find(key), user)

    user.with_lock do
      config = user.dashboard_config_hash
      user.update!(dashboard_config: config.merge('learning_tours' => (Array(config['learning_tours']).map(&:to_s) | [key])))
    end
  end

  def mark_checklist!(key)
    key = key.to_s
    raise ArgumentError, 'Unknown checklist item' unless GettingStartedChecklist::ITEM_KEYS.include?(key)

    user.with_lock do
      config = user.dashboard_config_hash
      user.update!(dashboard_config: config.merge('learning_checklist_done' => (Array(config['learning_checklist_done']).map(&:to_s) | [key])))
    end
  end

  private

  def default_focus
    preferred = if user.employee?
      'staff'
    elsif user.can?('settings.read')
      'setup'
    elsif user.can_use_pos?
      'checkout'
    elsif user.can?('reports.read')
      'books'
    elsif user.can?('inventory.read')
      'stock'
    elsif user.can_review_timesheets? || user.can_review_receipts?
      'manage'
    else
      'work'
    end
    paths.find { |path| path[:key] == preferred } || paths.first
  end

  def save!(changes)
    user.with_lock { user.update!(dashboard_config: user.dashboard_config_hash.merge(changes)) }
  end
end
