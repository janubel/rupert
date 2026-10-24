# frozen_string_literal: true

class CtraxSalesSyncJob < ApplicationJob
  queue_as :default

  RECHECK_DAYS = 7
  NIGHTLY_HOUR = 3

  # Today and yesterday on every run, plus any of the last week never stored; once a night (the run in the 3 a.m.
  # hour) the whole last week, so a correction to an older day in C-Trax is read again.
  def self.dates_to_read(now: Time.current)
    local = now.in_time_zone('America/New_York')
    today = local.to_date
    week = (0...RECHECK_DAYS).map { |back| today - back }
    return week if local.hour == NIGHTLY_HOUR && local.min < 30

    stored = CtraxDay.where(business_date: week.min..today).distinct.pluck(:business_date)
    ([today, today - 1] + (week - stored)).uniq
  end

  def perform(connection_id = nil, date: nil, manual: false)
    unless connection_id
      PosConnection.unscoped.joins(:tenant).where(provider: 'ctrax', reporting_enabled: true,
        tenants: { status: 'active' }).find_each { |connection| self.class.perform_later(connection.id) }
      return
    end
    connections = PosConnection.unscoped.where(id: connection_id, provider: 'ctrax', vendor_approved: true)
    connections = connections.where(reporting_enabled: true) unless manual
    connection = connections.first
    return unless connection&.tenant&.status == 'active' && connection.credentials_saved?

    Current.set(tenant: connection.tenant) do
      dates = date ? [Date.iso8601(date)] : self.class.dates_to_read
      dates.each do |day|
        result = Ctrax::SalesSync.call(connection: connection.reload, date: day)
        ActivityLogger.log('ctrax_sales_synced', subject: connection,
          details: "#{result[:date]}: #{result[:stores]} stores, #{result[:orders]} orders")
      end
    rescue Ctrax::Client::Error, Date::Error => e
      message = e.is_a?(Ctrax::Client::Error) ? e.message : 'Choose a valid business date.'
      PosConnection.where(id: connection.id, lock_version: connection.lock_version).update_all(last_report_status: 'failed', last_report_message: message)
      ActivityLogger.log('ctrax_sales_sync_failed', subject: connection, details: message)
    end
  end
end
