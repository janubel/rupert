# frozen_string_literal: true

module People
  class TimesheetEvent < ApplicationRecord
    include TenantScoped
    self.table_name = 'timesheet_events'
    belongs_to :timesheet, class_name: 'People::Timesheet'
    belongs_to :user, optional: true
    serialize :details, coder: JSON
  end
end
