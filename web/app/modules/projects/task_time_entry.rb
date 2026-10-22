# frozen_string_literal: true

module Projects
  class TaskTimeEntry < ApplicationRecord
    include TenantScoped

    self.table_name = 'task_time_entries'

    belongs_to :task, class_name: 'Projects::Task'
    belongs_to :user, optional: true

    validates :minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 24 * 60 }
    validates :logged_on, presence: true
    validates :note, length: { maximum: 200 }

    # "1.5", "1:30", "90m" and "2h" all work; blank or unreadable is nil.
    def self.parse_minutes(text)
      value = text.to_s.strip.downcase
      case value
      when /\A(\d+):(\d{1,2})\z/ then ($1.to_i * 60) + $2.to_i
      when /\A(\d+(?:\.\d+)?)\s*m(?:in(?:ute)?s?)?\z/ then $1.to_f.round
      when /\A(\d+(?:\.\d+)?)\s*(?:h(?:rs?|ours?)?)?\z/ then ($1.to_f * 60).round
      end
    end
  end
end
