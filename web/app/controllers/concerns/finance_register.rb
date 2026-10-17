# frozen_string_literal: true

# Shared parsing and audit-trail lookups for the expense and vendor-payment
# registers. Read-only: nothing here changes a record.
module FinanceRegister
  extend ActiveSupport::Concern
  include FinanceRegisterPeriod

  AMOUNT_FORMAT = /\A\d{1,9}(?:\.\d{1,2})?\z/

  private

  def register_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def register_cents(value)
    text = value.to_s.strip
    text.match?(AMOUNT_FORMAT) ? (BigDecimal(text) * 100).to_i : nil
  end

  # Custom from/to dates win over the "last N days" preset.
  def register_window(default_days: 90)
    from = register_date(params[:from])
    to = register_date(params[:to])
    if from || to
      to ||= Date.current
      from ||= to - 364
      from, to = to, from if from > to
      @range_days = nil
      [from, to]
    else
      load_finance_register_period
      [@from, @through]
    end
  end

  def register_like(text)
    "%#{ActiveRecord::Base.sanitize_sql_like(text.downcase)}%"
  end

  # { record id => [ActivityLog, ...] oldest first } for the rows on screen.
  def register_activity(type, ids)
    return {} if ids.empty?

    ActivityLog.where(subject_type: type, subject_id: ids.map(&:to_s)).order(:created_at).group_by(&:subject_id)
  end

  def register_locks
    PeriodLock.active_locks
  end
end
