# frozen_string_literal: true

require 'test_helper'

class TimeClockConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'different shifts of one worker cannot gain overlapping approved corrections' do
    tenant = Tenant.create!(name: 'Clock race', subdomain: "clock-race-#{SecureRandom.hex(4)}")
    Current.tenant = tenant
    user = User.create!(tenant: tenant, email: "clock-race-#{SecureRandom.hex(4)}@example.com", role: 'admin', password: 'password')
    worker = People::Employee.create!(user: user, first_name: 'Concurrent', last_name: 'Worker', employment_type: 'contractor')
    date = 2.days.ago.beginning_of_day
    shifts = [[9, 10], [12, 13]].map do |start_hour, end_hour|
      ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s,
        employee_name: worker.name, employment_type: worker.employment_type,
        started_at: date + start_hour.hours, ended_at: date + end_hour.hours, request_token: SecureRandom.uuid)
    end
    proposals = [[10.hours, 11.hours + 30.minutes], [11.hours, 12.hours + 30.minutes]]
    corrections = shifts.zip(proposals).map do |shift, (start_offset, end_offset)|
      TimeClockService.request_correction(user: user, shift_id: shift.id, attributes: {
        proposed_started_at: date + start_offset, proposed_ended_at: date + end_offset, reason: 'Concurrent correction'
      })
    end
    ready = Queue.new
    gate = Queue.new
    outcomes = Queue.new
    threads = corrections.map do |correction|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = tenant
          candidate = ClockCorrection.find(correction.id)
          reviewer = User.find(user.id)
          ready << true
          gate.pop
          TimeClockService.review(correction: candidate, reviewer: reviewer, approve: true)
          outcomes << :approved
        end
      rescue ActiveRecord::RecordInvalid
        outcomes << :overlap_rejected
      rescue StandardError => error
        outcomes << "#{error.class}: #{error.message}"
      ensure
        Current.reset
      end
    end
    threads.size.times { ready.pop }
    threads.size.times { gate << true }
    threads.each(&:join)
    result = []
    result << outcomes.pop until outcomes.empty?
    assert_equal [:approved, :overlap_rejected], result.sort_by(&:to_s)
    assert_equal 1, ClockCorrection.where(id: corrections.map(&:id), status: 'approved').count
    ordered = ClockShift.where(id: shifts.map(&:id)).order(:started_at).to_a
    assert_operator ordered.first.ended_at, :<=, ordered.last.started_at
  ensure
    Current.tenant = tenant
    ClockCorrection.where(clock_shift_id: shifts&.map(&:id)).delete_all if shifts
    ClockShift.where(id: shifts&.map(&:id)).delete_all if shifts
    worker&.destroy!
    user&.destroy!
    tenant&.destroy!
    Current.reset
  end
end
