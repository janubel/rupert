# frozen_string_literal: true

require 'json'
require 'timeout'

# Read side of Rupert's Buzz connection: opens a WebSocket to the relay as the
# @rupert agent, answers the NIP-42 challenge, sends one REQ and returns the
# stored events it gets back before EOSE. Used for the Team chat history and the
# people's profile names. (BuzzAgent publishes; BuzzListener keeps a live
# subscription for the agent's replies.)
#
# Protocol, checked against github.com/block/buzz (ARCHITECTURE.md, 2026-10-22):
#   * the relay sends ["AUTH", challenge] on connect; EVENT and REQ before a
#     successful AUTH are refused, so the REQ goes out after the relay's OK;
#   * a channel REQ carries "#h": [channel uuid]; the relay checks the agent is a
#     member of the channel and answers ["CLOSED", sub, "restricted: ..."] if not;
#   * at most 500 stored events per filter, newest first, then ["EOSE", sub];
#   * channel messages are kind 9 (and 40002, "stream message v2").
#
# Every failure is raised as BuzzRelayClient::Error with a short, key-free reason.
class BuzzRelayClient
  class Error < StandardError; end

  MAX_EVENTS = 600
  CONNECT_TIMEOUT = 6
  AUTH_WAIT = 5.0

  class << self
    # Events matching the filters (newest first as the relay sends them).
    def query(filters, timeout: 10)
      new.query(filters, timeout: timeout)
    end

    # Publishes a signed event; returns [true, message] or [false, reason].
    def publish(event, timeout: 10)
      new.publish(event, timeout: timeout)
    end
  end

  # Unlike BuzzAgent.publish this waits for the relay to accept the sign-in
  # before the event goes out, and only counts the OK for the event's own id.
  def publish(event, timeout: 10)
    return [false, 'Buzz is not configured'] unless BuzzAgent.configured?

    require 'websocket-client-simple'
    relay = BuzzAgent.relay_url
    frames = Queue.new
    ws = open_socket(relay, frames)
    wait_until_open(ws, frames)
    authenticate(ws, frames, relay)
    ws.send(['EVENT', event.to_h].to_json)
    deadline = Time.now + timeout
    loop do
      frame = pop(frames, deadline - Time.now)
      return [false, 'the relay did not answer in time'] if frame.nil?
      return [false, 'the relay closed the connection'] if %w[ERROR CLOSE].include?(frame[0])
      next unless frame[0] == 'OK' && frame[1] == event.id

      return frame[2] == true ? [true, frame[3].presence || 'OK'] : [false, frame[3].to_s.presence&.first(200) || 'the relay refused the message']
    end
  rescue Error => e
    [false, e.message]
  rescue SystemCallError, SocketError, IOError
    [false, 'the relay is not reachable']
  rescue StandardError => e
    [false, "could not reach the relay (#{e.class.name.demodulize})"]
  ensure
    close(ws)
  end

  def query(filters, timeout: 10)
    raise Error, 'Buzz is not configured' unless BuzzAgent.configured?

    require 'websocket-client-simple'
    relay = BuzzAgent.relay_url
    frames = Queue.new
    ws = open_socket(relay, frames)
    wait_until_open(ws, frames)
    authenticate(ws, frames, relay)
    collect(ws, frames, Array(filters), Time.now + timeout)
  rescue Error
    raise
  rescue Timeout::Error
    raise Error, 'the relay did not answer in time'
  rescue SystemCallError, SocketError, IOError
    raise Error, 'the relay is not reachable'
  rescue StandardError => e
    raise Error, "could not read from the relay (#{e.class.name.demodulize})"
  ensure
    close(ws)
  end

  private

  # websocket-client-simple evaluates handler blocks with self = the socket, so
  # they only use the locals they close over.
  # Handlers are registered before the connection starts (the block form of
  # connect): a relay sends its AUTH challenge the moment the socket opens, and
  # a handler added afterwards can miss it.
  def open_socket(relay, frames)
    WebSocket::Client::Simple.connect(relay) do |ws|
      ws.on(:message) do |msg|
        if msg.respond_to?(:type) && msg.type == :ping
          ws.send(msg.data.to_s, type: :pong)
          next
        end
        next if msg.respond_to?(:type) && msg.type != :text

        frames << JSON.parse(msg.data.to_s)
      rescue JSON::ParserError
        nil
      end
      ws.on(:error) { |e| frames << ['ERROR', e.message.to_s[0, 120]] }
      ws.on(:close) { frames << ['CLOSE'] }
    end
  end

  def wait_until_open(ws, frames)
    deadline = Time.now + CONNECT_TIMEOUT
    until ws.open?
      raise Error, 'the relay is not reachable' if Time.now > deadline
      raise Error, 'the relay is not reachable' if closed_frame?(frames)

      sleep 0.03
    end
  end

  def closed_frame?(frames)
    return false if frames.empty?

    frame = frames.pop(true)
    frames << frame unless %w[ERROR CLOSE].include?(frame[0])
    %w[ERROR CLOSE].include?(frame[0])
  rescue ThreadError
    false
  end

  # Waits for the relay's challenge and answers it. A relay that never
  # challenges is fine: the REQ is simply sent unauthenticated.
  def authenticate(ws, frames, relay)
    challenge = nil
    deadline = Time.now + AUTH_WAIT
    while challenge.nil? && Time.now < deadline
      frame = pop(frames, deadline - Time.now)
      break if frame.nil?

      challenge = frame[1] if frame[0] == 'AUTH'
      raise Error, 'the relay closed the connection' if %w[ERROR CLOSE].include?(frame[0])
    end
    return if challenge.nil?

    auth = BuzzAgent.build_auth_event(challenge, relay: relay)
    ws.send(['AUTH', auth.to_h].to_json)
    wait_for_ok(frames, auth.id)
  end

  def wait_for_ok(frames, event_id)
    deadline = Time.now + AUTH_WAIT
    loop do
      frame = pop(frames, deadline - Time.now)
      return if frame.nil?
      next unless frame[0] == 'OK' && frame[1] == event_id

      raise Error, "the relay refused Rupert's sign-in (#{frame[3].to_s[0, 80]})" unless frame[2] == true

      return
    end
  end

  def collect(ws, frames, filters, deadline)
    sub = "rupert-#{SecureRandom.hex(4)}"
    ws.send(['REQ', sub, *filters].to_json)
    events = []
    loop do
      frame = pop(frames, deadline - Time.now)
      raise Error, 'the relay did not answer in time' if frame.nil?

      case frame[0]
      when 'EVENT' then events << frame[2] if frame[1] == sub && frame[2].is_a?(Hash) && events.size < MAX_EVENTS
      when 'EOSE' then return events if frame[1] == sub
      when 'CLOSED' then raise Error, closed_reason(frame[2]) if frame[1] == sub
      when 'ERROR', 'CLOSE' then raise Error, 'the relay closed the connection'
      end
    end
  end

  def closed_reason(text)
    reason = text.to_s.tr("\n", ' ')[0, 80]
    return 'Rupert is not a member of this channel (add its public key to the channel in Buzz)' if reason.start_with?('restricted')
    return 'the relay would not let Rupert read (sign-in refused)' if reason.start_with?('auth-required')

    "the relay refused the request (#{reason})"
  end

  def pop(frames, seconds)
    return nil if seconds <= 0

    Timeout.timeout(seconds) { frames.pop }
  rescue Timeout::Error
    nil
  end

  def close(ws)
    ws&.close
  rescue StandardError
    nil
  end
end
