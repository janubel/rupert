# frozen_string_literal: true

require 'socket'
require 'json'
require 'digest'
require 'securerandom'
require 'monitor'
require 'websocket/driver'
require 'nostr'

# A small in-process Buzz relay for tests and local development. It speaks the
# parts of the protocol Rupert uses, as checked against github.com/block/buzz
# (ARCHITECTURE.md):
#
#   * sends ["AUTH", challenge] on connect and checks the kind 22242 answer
#     (challenge and relay tags, signature); EVENT and REQ before that are refused
#   * REQ with kinds, authors, #h, since, until, limit (500 max), newest first,
#     then EOSE; a REQ for a channel the key is not a member of gets
#     ["CLOSED", sub, "restricted: ..."]
#   * EVENT is signature-checked, stored, acknowledged with OK and fanned out to
#     live subscriptions (including the sender's own, like the real relay)
#
# It is a stand-in for development only; it never talks to a real Buzz relay.
class FakeBuzzRelay
  MAX_LIMIT = 500

  attr_reader :port, :events, :requests, :published
  # When set, EVENT is answered ["OK", id, false, reject_events] and not stored.
  attr_accessor :reject_events

  # members: nil lets any authenticated key read; otherwise an array of pubkeys.
  def initialize(channel:, host: '127.0.0.1', port: 0, members: nil, require_auth: true)
    @channel = channel
    @host = host
    @bind_port = port
    @members = members
    @require_auth = require_auth
    @events = []
    @requests = []
    @published = []
    @connections = []
    @lock = Mutex.new
    @refuse = false
    @delay = 0
  end

  def url = "ws://#{@host}:#{@port}"

  def start
    @server = TCPServer.new(@host, @bind_port)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
    self
  end

  def stop
    @server&.close
    @lock.synchronize { @connections.dup }.each(&:close)
    @thread&.kill
  rescue StandardError
    nil
  end

  # While true, new connections are accepted and dropped at once.
  def refuse_connections=(value)
    @refuse = value
  end

  # Seconds to wait before answering a REQ (to test timeouts).
  def delay=(seconds)
    @delay = seconds
  end

  # Stores an event as if someone had published it, and delivers it to live
  # subscribers. Ephemeral kinds (20000-29999, e.g. typing) are delivered only,
  # never stored, as the real relay does.
  def add(event)
    store(event) unless (20_000..29_999).cover?(event['kind'].to_i)
    fan_out(event)
    event
  end

  def self.keypair
    pair = Nostr::Keygen.new.generate_key_pair
    { private_key: pair.private_key, public_key: pair.public_key.to_s, pair: pair }
  end

  # A signed event as a plain hash, the way it travels on the wire.
  def self.signed(key, kind:, content:, tags: [], created_at: Time.now.to_i)
    event = Nostr::Event.new(pubkey: Nostr::PublicKey.new(key[:public_key]), kind: kind, content: content, tags: tags, created_at: created_at)
    event.sign(key[:private_key])
    event.to_h.transform_keys(&:to_s).merge('pubkey' => key[:public_key])
  end

  def message(key, text, at: Time.now.to_i, channel: @channel, kind: 9, extra_tags: [])
    self.class.signed(key, kind: kind, content: text, tags: [['h', channel]] + extra_tags, created_at: at)
  end

  def profile(key, **fields)
    self.class.signed(key, kind: 0, content: fields.to_json)
  end

  def self.match?(filter, event)
    return false if filter['kinds'] && !filter['kinds'].include?(event['kind'])
    return false if filter['authors'] && !filter['authors'].include?(event['pubkey'])
    return false if filter['since'] && event['created_at'] < filter['since']
    return false if filter['until'] && event['created_at'] > filter['until']

    filter.each do |key, wanted|
      next unless key.start_with?('#')

      values = event['tags'].select { |t| t[0] == key[1..] }.map { |t| t[1] }
      return false if (values & Array(wanted)).empty?
    end
    true
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      if @refuse
        socket.close
        next
      end
      conn = Connection.new(socket, self)
      @lock.synchronize { @connections << conn }
      Thread.new { conn.run }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def store(event)
    @lock.synchronize do
      @events << event unless @events.any? { |e| e['id'] == event['id'] }
    end
  end

  def fan_out(event)
    @lock.synchronize { @connections.dup }.each { |conn| conn.deliver(event) }
  end

  def query(filters)
    found = filters.flat_map do |filter|
      list = @lock.synchronize { @events.dup }.select { |e| FakeBuzzRelay.match?(filter, e) }
      list = list.sort_by { |e| [-e['created_at'], e['id']] }
      list.first([filter['limit'].to_i.positive? ? filter['limit'].to_i : MAX_LIMIT, MAX_LIMIT].min)
    end
    found.uniq { |e| e['id'] }
  end

  def member?(pubkey) = @members.nil? || @members.include?(pubkey)

  def channels_in(filters) = filters.flat_map { |f| Array(f['#h']) }

  def record_request(filters) = @lock.synchronize { @requests << filters }

  def record_published(event) = @lock.synchronize { @published << event }

  def forget(conn) = @lock.synchronize { @connections.delete(conn) }

  # One WebSocket client.
  class Connection
    def initialize(socket, relay)
      @socket = socket
      @relay = relay
      @challenge = SecureRandom.hex(16)
      @pubkey = nil
      @subs = {}
      @write_lock = Monitor.new
      @driver = WebSocket::Driver.server(self)
      @driver.on(:connect) { @driver.start }
      @driver.on(:open) { send_frame(['AUTH', @challenge]) if relay_requires_auth? }
      @driver.on(:message) { |e| handle(e.data) }
    end

    def url = "ws://127.0.0.1/"

    def write(data)
      @write_lock.synchronize { @socket.write(data) }
    rescue StandardError
      nil
    end

    def run
      loop { @driver.parse(@socket.readpartial(8192)) }
    rescue EOFError, IOError, SystemCallError
      nil
    ensure
      @relay.send(:forget, self)
      close
    end

    def close
      @socket.close unless @socket.closed?
    rescue StandardError
      nil
    end

    def deliver(event)
      @subs.each do |sub, filters|
        send_frame(['EVENT', sub, event]) if filters.any? { |f| FakeBuzzRelay.match?(f, event) }
      end
    end

    private

    def relay_requires_auth? = @relay.instance_variable_get(:@require_auth)

    def send_frame(frame)
      @write_lock.synchronize { @driver.text(frame.to_json) }
    rescue StandardError
      nil
    end

    def handle(raw)
      frame = JSON.parse(raw)
      case frame[0]
      when 'AUTH' then authenticate(frame[1])
      when 'REQ' then request(frame[1], frame[2..])
      when 'EVENT' then publish(frame[1])
      when 'CLOSE' then @subs.delete(frame[1])
      end
    rescue JSON::ParserError
      send_frame(['NOTICE', 'invalid frame'])
    end

    def authenticate(event)
      ok = event.is_a?(Hash) && event['kind'] == 22_242 && valid_signature?(event) &&
           event['tags'].include?(['challenge', @challenge]) && event['tags'].any? { |t| t[0] == 'relay' }
      @pubkey = event['pubkey'] if ok
      send_frame(['OK', event['id'], ok ? true : false, ok ? '' : 'auth-failed: bad challenge response'])
    end

    def request(sub, filters)
      @relay.send(:record_request, filters)
      if relay_requires_auth? && @pubkey.nil?
        return send_frame(['CLOSED', sub, 'auth-required: authenticate first'])
      end

      channels = @relay.send(:channels_in, filters)
      if channels.any? && !@relay.send(:member?, @pubkey)
        return send_frame(['CLOSED', sub, 'restricted: not a channel member'])
      end

      sleep @relay.instance_variable_get(:@delay).to_f
      @relay.send(:query, filters).each { |event| send_frame(['EVENT', sub, event]) }
      @subs[sub] = filters
      send_frame(['EOSE', sub])
    end

    def publish(event)
      return send_frame(['OK', event && event['id'], false, 'invalid: malformed event']) unless event.is_a?(Hash)
      if relay_requires_auth? && @pubkey.nil?
        return send_frame(['OK', event['id'], false, 'auth-required: authenticate first'])
      end
      return send_frame(['OK', event['id'], false, 'invalid: bad signature']) unless valid_signature?(event)
      return send_frame(['OK', event['id'], false, @relay.reject_events]) if @relay.reject_events
      return send_frame(['OK', event['id'], false, 'restricted: not a relay member']) unless @relay.send(:member?, event['pubkey'])

      @relay.send(:record_published, event)
      @relay.add(event)
      send_frame(['OK', event['id'], true, ''])
    end

    def valid_signature?(event)
      digest = Digest::SHA256.hexdigest(JSON.generate([0, event['pubkey'], event['created_at'], event['kind'], event['tags'], event['content']]))
      return false unless digest == event['id']

      Nostr::Event.new(id: event['id'], pubkey: event['pubkey'], created_at: event['created_at'], kind: event['kind'],
        tags: event['tags'], content: event['content'], sig: event['sig']).verify_signature
    rescue StandardError
      false
    end
  end
end
