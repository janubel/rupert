# frozen_string_literal: true

# A local stand-in for a Buzz relay, for developing and trying the Team chat tab
# without a real community. Development only; it never talks to a real relay.
#
#   bin/rails runner scripts/dev_buzz_relay.rb [port] [--live]
#
# It points this development database's Buzz settings at itself (relay address,
# a channel id, and a throwaway agent key if none exists), fills the channel with
# sample history (several people, the Rupert agent, links, long and hostile text)
# and then serves until stopped. --live adds a new message every 15 seconds.
abort 'This stand-in is for development only.' unless Rails.env.development?

require Rails.root.join('test/support/fake_buzz_relay')

port = (ARGV.find { |arg| arg =~ /\A\d+\z/ } || 7777).to_i
live = ARGV.include?('--live')
channel = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'

Current.tenant = Tenant.find_by(status: 'active') || Tenant.first
abort 'No tenant found (create one first).' unless Current.tenant

BuzzAgent.generate_keypair! if BuzzAgent.private_key_hex.blank?
relay = FakeBuzzRelay.new(channel: channel, port: port).start
EnvStore.set('BUZZ_RELAY_URL', relay.url)
EnvStore.set('BUZZ_CHANNEL', channel)

agent = { private_key: BuzzAgent.private_key, public_key: BuzzAgent.public_key_hex }
people = {
  maria: FakeBuzzRelay.keypair, devon: FakeBuzzRelay.keypair, priya: FakeBuzzRelay.keypair, stranger: FakeBuzzRelay.keypair
}
relay.add(relay.profile(people[:maria], name: 'maria', display_name: 'Maria Lopez'))
relay.add(relay.profile(people[:devon], name: 'devon'))
relay.add(relay.profile(people[:priya], display_name: 'Priya N.'))
relay.add(relay.profile(agent, name: 'Rupert', display_name: 'Rupert'))

lines = [
  [:maria, 'Morning all. Opening the shop at 9, anyone seen the new shipment of *candles*?'],
  [:devon, 'Delivery is booked for **Thursday**. Tracking: https://example.com/track/12345.'],
  [:priya, "Counts for the back room are done.\nTwo SKUs were off by one, I left notes in the sheet."],
  [:agent, 'Square sync finished: 0 changes, 41 items checked.'],
  [:stranger, 'hi, is this the right channel for wholesale questions?'],
  [:maria, 'Yes! Ask away. Also see `inventory > alerts` for low stock.'],
  [:devon, 'Heads up: <script>alert("hi")</script> shows up in a customer note again, escaping looks fine though.'],
  [:priya, 'Long one: ' + ('the quick brown fox jumps over the lazy dog ' * 12)],
  [:agent, 'Low stock: 3 items are at zero on Shopify. Open Inventory > Alerts to see which.'],
  [:maria, 'https://example.com/a/really/long/path/that/keeps/going/and/going/and/going/and/going/and/going/and/going?with=query&and=more']
]
now = Time.now.to_i
count = 150
count.times do |i|
  who, text = lines[i % lines.size]
  text = "#{text} (##{i + 1})" if i >= lines.size
  key = who == :agent ? agent : people[who]
  relay.add(relay.message(key, text, at: now - ((count - i) * 1500)))
end
relay.add(relay.message(agent, 'Sam via Rupert: posted from the Team chat tab in Rupert.', at: now - 90, extra_tags: [['client', BuzzChat::CLIENT_TAG]]))

puts "Dev Buzz relay on #{relay.url}, channel #{channel}, #{relay.events.size} events. Ctrl-C to stop."
if live
  Thread.new do
    n = 0
    loop do
      sleep 15
      n += 1
      key = people.values[n % people.size]
      relay.add(relay.message(key, "Live message ##{n} at #{Time.now.strftime('%H:%M:%S')}", at: Time.now.to_i))
    end
  end
end
sleep
