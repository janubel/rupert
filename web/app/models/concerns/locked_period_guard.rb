# frozen_string_literal: true

# Refuses to add, change or remove a record dated inside a locked month,
# quarter or year (see PeriodLock). Both the old and the new date are checked,
# so a record cannot be moved into or out of a locked period either.
#
#   guard_locked_period :incurred_on
#   guard_locked_period range: ->(r) { [r.period_from, r.period_to] }
#
# Runs as a validation (so forms show the reason) and again before save, which
# also covers update_attribute paths such as discard/undiscard.
module LockedPeriodGuard
  extend ActiveSupport::Concern

  class_methods do
    def guard_locked_period(attribute = nil, range: nil)
      spans = lambda do |record|
        current = range ? Array(range.call(record)) : [record.public_send(attribute)]
        before = []
        if record.persisted?
          before = range ? [record.attribute_in_database(:period_from), record.attribute_in_database(:period_to)] : [record.attribute_in_database(attribute)]
        end
        [current.compact, before.compact].reject(&:empty?).map { |dates| [dates.min, dates.max] }
      end

      validate { |record| record.send(:add_locked_period_error, spans.call(record)) }
      before_save do |record|
        next unless record.send(:add_locked_period_error, spans.call(record))

        throw :abort
      end
    end
  end

  private

  def add_locked_period_error(spans)
    return false if new_record? == false && !has_changes_to_save?

    lock = spans.lazy.filter_map { |first, last| PeriodLock.lock_covering(first, last) }.first
    return false unless lock

    message = PeriodLock.locked_message(lock)
    errors.add(:base, message) unless errors[:base].include?(message)
    true
  end
end
