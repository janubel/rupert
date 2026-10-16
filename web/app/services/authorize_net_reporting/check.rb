# frozen_string_literal: true

module AuthorizeNetReporting
  class Check
    def self.call(connection:)
      client = Client.new(connection)
      client.merchant
      batches = client.batches(from: 1.day.ago, to: Time.current)
      rows = client.transactions
      batch_rows = batches.any? ? client.transactions(batch_id: batches.first.fetch('batchId')) : []
      sample = rows.first || batch_rows.first
      client.detail(sample.fetch('transId')) if sample
      message = 'Merchant, settlement batch and unsettled reporting access checked.'
      message += batches.any? ? ' Settled transaction list access checked.' : ' No batch was available to verify settled transaction list access.'
      message += sample ? ' A transaction detail was also read.' : ' No transaction was available to verify detail access.'
      { status: 'verified', message: message }
    rescue Client::Error => e
      { status: 'failed', message: e.message }
    end
  end
end
