# frozen_string_literal: true

module PaymentProviders
  class CtraxCheck
    def self.call(credentials:)
      client = Ctrax::Client.new(credentials)
      stores = client.stores
      # Merchant setup is optional and may require different permissions.
      merchant_counts = stores.map do |store|
        client.merchant_summary(store[:id])
      rescue Ctrax::Client::Error
        nil
      end
      message = "C-Trax login verified for #{stores.size} stores. "
      message += if merchant_counts.all?
        "TRX merchant settings list #{merchant_counts.sum do |counts|
                     counts[:production]
                   end} production and #{merchant_counts.sum do |counts|
                                         counts[:sandbox]
                                       end} sandbox accounts. "
      else
        'TRX merchant settings could not be read for every store. '
                 end
      message += 'Stock access is checked by Sync stock; merchant settings do not establish inventory or settlement access.'
      { status: 'verified', message: message }
    rescue Ctrax::Client::Error => e
      { status: 'failed', message: e.message }
    end
  end
end
