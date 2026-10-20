# frozen_string_literal: true

# Personal learning preferences live alongside the user's other workspace preferences.
# Writes lock the user so answering a lesson cannot overwrite another learning update.
class LearningJourney
  PATHS = [
    { key: 'setup', label: 'Set up my workspace', lessons: %w[start setup] },
    { key: 'checkout', label: 'Serve customers', lessons: %w[start checkout sales] },
    { key: 'stock', label: 'Look after stock', lessons: %w[start stock counts] },
    { key: 'books', label: 'Understand sales and close the books', lessons: %w[start sales books] },
    { key: 'work', label: 'Organize projects and goals', lessons: %w[start work] },
    { key: 'staff', label: 'Manage my hours and receipts', lessons: %w[start staff] }
  ].freeze

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def lessons
    @lessons ||= LearningCatalog.available(user)
  end

  def paths
    PATHS.select { |path| lessons.any? { |lesson| lesson[:key] == path[:key] } }
  end

  def focus
    paths.find { |path| path[:key] == user.dashboard_config_hash['learning_focus'] } || default_focus
  end

  def path_lessons
    focus[:lessons].filter_map { |key| lessons.find { |lesson| lesson[:key] == key } }
  end

  def completed
    Array(user.dashboard_config_hash['learning_completed']) & lessons.pluck(:key)
  end

  def next_lesson
    path_lessons.find { |lesson| !completed.include?(lesson[:key]) }
  end

  def welcome?
    !user.dashboard_config_hash['learning_welcome_hidden'] && next_lesson.present?
  end

  def choose!(key)
    return false unless paths.any? { |path| path[:key] == key }

    save!('learning_focus' => key, 'learning_welcome_hidden' => false)
    true
  end

  def dismiss!
    save!('learning_welcome_hidden' => true)
  end

  def complete!(key)
    raise ArgumentError, 'Unavailable lesson' unless lessons.any? { |lesson| lesson[:key] == key }

    user.with_lock do
      config = user.dashboard_config_hash
      user.update!(dashboard_config: config.merge('learning_completed' => (Array(config['learning_completed']) | [key])))
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
    else
      'work'
    end
    paths.find { |path| path[:key] == preferred } || paths.last
  end

  def save!(changes)
    user.with_lock { user.update!(dashboard_config: user.dashboard_config_hash.merge(changes)) }
  end
end
