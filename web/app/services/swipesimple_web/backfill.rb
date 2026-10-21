# frozen_string_literal: true

module SwipesimpleWeb
  # One-time, owner-run pull of SwipeSimple's tax and sales reports for a past
  # date range, one calendar month per request with a pause between requests.
  # Read-only toward SwipeSimple. Each month is checked and stored on its own,
  # so a failure stops the run but keeps every month already stored.
  class Backfill
    MAX_DAYS = 3 * 366

    def self.call(connection:, from:, to:, pause: 2, log: ->(_line) {})
      raise ArgumentError, 'Choose an ordered date range.' unless from.is_a?(Date) && to.is_a?(Date) && from <= to
      raise ArgumentError, "Choose a range of #{MAX_DAYS} days or fewer." if (to - from).to_i >= MAX_DAYS
      raise ArgumentError, 'The range cannot end in the future.' if to > ReportStore.today
      unless connection.provider == 'swipesimple' && connection.tenant_id == Current.tenant_id && connection.vendor_approved && connection.credentials_saved?
        raise Client::Error, :invalid
      end

      account = ReportStore.verified_account
      client = Client.new(connection.credential_values, company_id: connection.account_reference)
      stored = 0
      Client.months(from, to).each_with_index do |(first, last), index|
        Client::REPORT_TOPICS.each_with_index do |topic, position|
          sleep(pause) if pause.positive? && (index.positive? || position.positive?)
          chunk = client.report(topic, from: first, to: last).sole
          ReportStore.replace!(chunk, merchant_account: account)
          stored += 1
          log.call("#{topic} #{first}..#{last}: #{chunk.rows.size} rows stored")
        end
      end
      { months: stored / Client::REPORT_TOPICS.size, from: from, to: to }
    end
  end
end
