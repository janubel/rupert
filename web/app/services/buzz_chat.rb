# frozen_string_literal: true

require 'digest'
require 'json'

# The Team chat tab on the Buzz page: the configured channel's recent messages
# (kept as a short-lived copy so the page is quick and still works while the
# relay is briefly out of reach), the names of the people who wrote them, and
# posting.
#
# Everything that comes from the relay is untrusted text from other people. It is
# checked (id, signature, channel), cleaned, capped and stored as text; the page
# only ever shows it as text. Nothing linked from a message is fetched.
#
# Posting identity (v1): messages go out signed by the @rupert agent key with a
# visible prefix, "Sam via Rupert: ...", and a `client` tag. Rupert holds no
# per-person Nostr keys. Because of that the relay, the Buzz apps and the intake
# allow-list see the AGENT as the sender, never the person, so a message posted
# here can never mark work "ready for development" (FeedbackIntake refuses the
# agent's own key as a sender). Neither the private key nor any nsec is ever
# logged or shown.
class BuzzChat
  class Error < StandardError; end
  class NotReady < Error; end
  class Invalid < Error; end
  class RateLimited < Error; end
  class PostFailed < Error; end

  KINDS = [9, 40_002].freeze # stream message, stream message v2
  PAGE = 40
  SYNC_LIMIT = 100
  CATCH_UP_LIMIT = 500 # the relay's cap per filter
  CATCH_UP_OVERLAP = 120 # seconds re-read behind the newest cached message
  OLDER_FETCH = 100
  RETENTION = 30.days
  POST_MAX = 1500
  POST_LIMITS = { 1.minute => 6, 1.hour => 60 }.freeze
  CLIENT_TAG = 'rupert-chat'
  VIA = ' via Rupert: '
  NSEC = /nsec1[02-9ac-hj-np-z]{20,}/i
  CONTROL = /[^\P{Cc}\n\t]/
  HEX64 = /\A\h{64}\z/
  PROFILE_BATCH = 50

  class << self
    # :unconfigured (no relay or no agent key), :no_channel, or :ready.
    def state
      return :unconfigured unless BuzzAgent.configured?

      BuzzAgent.channel_id.present? ? :ready : :no_channel
    end

    def ready? = state == :ready

    def channel = BuzzAgent.channel_id

    def agent_pubkey
      BuzzAgent.public_key_hex.presence
    rescue StandardError
      nil
    end

    # --- reading ---

    # Asks the relay for what is new (or the latest page on first use) and
    # stores it. Returns the number of new messages, or nil when the relay could
    # not be read; the reason is kept for the page. Never raises.
    def sync!
      return unless ready?

      newest = messages_scope.maximum(:posted_at)
      filter = { kinds: KINDS, '#h': [channel] }
      if newest
        filter[:since] = [newest - CATCH_UP_OVERLAP, 0].max
        filter[:limit] = CATCH_UP_LIMIT
      else
        filter[:limit] = SYNC_LIMIT
      end
      events = BuzzRelayClient.query([filter])
      drop_gap(events) if newest && events.size >= CATCH_UP_LIMIT
      stored = ingest(events)
      refresh_profiles
      BuzzChatState.succeeded!
      stored
    rescue BuzzRelayClient::Error => e
      BuzzChatState.failed!(e.message)
      nil
    rescue StandardError => e
      Rails.logger.error("[BuzzChat] sync: #{e.class}")
      BuzzChatState.failed!('Rupert could not read the channel just now')
      nil
    end

    # Messages for the page, oldest first, as { messages:, has_more: }.
    #   before: cursor  -> a page of earlier messages (asks the relay when the copy runs out)
    #   after:  cursor  -> messages newer than the cursor
    #   neither         -> the latest page
    def page(before: nil, after: nil, limit: PAGE, viewer: nil)
      limit = limit.to_i.clamp(1, 100)
      rows, has_more, older_failed =
        if after
          [messages_scope.newer_than(after).oldest_first.limit(limit * 3).to_a, false, false]
        elsif before
          older_page(before, limit)
        else
          latest_page(limit)
        end
      { messages: present(rows, viewer: viewer), has_more: has_more, older_failed: older_failed }
    end

    def empty_cache? = messages_scope.none?

    # What the page shows about the connection.
    def status
      row = BuzzChatState.current
      { state: state, synced_at: row.last_success_at, error: row.last_error, channel: channel.presence }
    end

    # Cached messages as plain hashes for the browser. Text is returned raw;
    # the page renders it as text (textContent), never as HTML.
    def present(rows, viewer: nil)
      pubkeys = rows.map(&:pubkey).uniq
      names = BuzzProfile.where(pubkey: pubkeys).index_by(&:pubkey)
      agent = agent_pubkey
      rows.map { |row| present_one(row, names[row.pubkey], agent, viewer) }
    end

    # --- writing ---

    # Posts as the Rupert agent. Raises NotReady, Invalid, RateLimited or
    # PostFailed with a message that is safe to show.
    def post!(user:, text:)
      raise NotReady, 'Team chat is not set up yet.' unless ready?

      clean = clean_post(text)
      enforce_rate_limit!(user)
      event = BuzzAgent.build_event(content: "#{sender_name(user)}#{VIA}#{clean}", channel: channel, tags: [['client', CLIENT_TAG]])
      ok, reason = BuzzRelayClient.publish(event)
      unless ok
        Rails.logger.warn("[BuzzChat] post failed for user #{user.id}: #{reason.to_s[0, 120]}")
        raise PostFailed, 'Rupert could not reach Buzz, so your message was not sent. Try again in a moment.'
      end

      row = store_posted(event, user)
      ActivityLogger.log('buzz_chat_post', details: "event=#{event.id[0, 12]} chars=#{clean.length}")
      row
    end

    # Deletes copies past the retention window. Run per tenant.
    def purge!(now: Time.current)
      cutoff = (now - RETENTION).to_i
      removed = BuzzMessage.where(posted_at: ...cutoff).delete_all
      BuzzProfile.where(fetched_at: ...(now - 90.days)).delete_all
      removed
    end

    def short_npub(pubkey)
      npub = Nostr::PublicKey.new(pubkey).to_bech32
      "#{npub[0, 12]}…#{npub[-4..]}"
    rescue StandardError
      "#{pubkey.to_s[0, 8]}…"
    end

    private

    def messages_scope = BuzzMessage.in_channel(channel)

    def latest_page(limit)
      rows = messages_scope.newest_first.limit(limit + 1).to_a
      [rows.first(limit).reverse, rows.size > limit, false]
    end

    def older_page(cursor, limit)
      failed = false
      if messages_scope.older_than(cursor).limit(limit + 1).count <= limit
        failed = !fetch_older(cursor)
      end
      rows = messages_scope.older_than(cursor).newest_first.limit(limit + 1).to_a
      [rows.first(limit).reverse, rows.size > limit || failed, failed]
    end

    def fetch_older(cursor)
      return false unless ready?

      events = BuzzRelayClient.query([{ kinds: KINDS, '#h': [channel], until: cursor[0], limit: OLDER_FETCH }])
      ingest(events)
      refresh_profiles
      true
    rescue BuzzRelayClient::Error
      false
    end

    # More new messages arrived than one request returns: the copy is no longer
    # contiguous, so forget what is older than the newest batch.
    def drop_gap(events)
      oldest = events.filter_map { |e| e['created_at'].to_i if e.is_a?(Hash) }.min
      messages_scope.where(posted_at: ...oldest).delete_all if oldest
    end

    # Validates and stores relay events; returns how many were new.
    def ingest(events)
      now = Time.current
      rows = Array(events).filter_map { |event| row_for(event, now) }
      return 0 if rows.empty?

      before = BuzzMessage.count
      BuzzMessage.insert_all(rows, unique_by: :idx_buzz_messages_event)
      BuzzMessage.count - before
    end

    def row_for(event, now)
      return unless valid_event?(event)

      tags = event['tags']
      return unless tags.any? { |t| t[0] == 'h' && t[1] == channel }

      {
        tenant_id: Current.tenant_id, event_id: event['id'], pubkey: event['pubkey'], kind: event['kind'], channel: channel,
        content: clean_incoming(event['content']), reply_to: reply_target(tags), client: client_tag(tags),
        posted_at: event['created_at'], created_at: now, updated_at: now
      }
    end

    def valid_event?(event)
      return false unless event.is_a?(Hash)
      return false unless event['id'].to_s.match?(HEX64) && event['pubkey'].to_s.match?(HEX64) && event['sig'].to_s.match?(/\A\h{128}\z/)
      return false unless KINDS.include?(event['kind']) && event['content'].is_a?(String) && event['tags'].is_a?(Array)
      return false unless event['tags'].all? { |t| t.is_a?(Array) && t.all?(String) }
      return false unless event['created_at'].is_a?(Integer) && event['created_at'].between?(1_500_000_000, Time.now.to_i + 86_400)

      signed_correctly?(event)
    end

    def signed_correctly?(event)
      digest = Digest::SHA256.hexdigest(JSON.generate([0, event['pubkey'], event['created_at'], event['kind'], event['tags'], event['content']]))
      return false unless digest == event['id']

      Nostr::Event.new(id: event['id'], pubkey: event['pubkey'], created_at: event['created_at'], kind: event['kind'],
        tags: event['tags'], content: event['content'], sig: event['sig']).verify_signature
    rescue StandardError
      false
    end

    def clean_incoming(text)
      text.to_s.scrub('').gsub(CONTROL, '').gsub(NSEC, '[private key removed]').strip.first(BuzzMessage::CONTENT_MAX)
    end

    def reply_target(tags)
      tags.find { |t| t[0] == 'e' && t[1].to_s.match?(HEX64) }&.at(1)
    end

    def client_tag(tags)
      value = tags.find { |t| t[0] == 'client' }&.at(1).to_s
      value.match?(/\A[a-z0-9._-]{1,40}\z/) ? value : nil
    end

    # --- people ---

    # Looks up the kind 0 profiles of authors we have no fresh name for. One
    # relay call for the batch; an author with no profile is remembered as
    # nameless so it is not asked again until the refresh window passes.
    def refresh_profiles
      known = BuzzProfile.fresh.pluck(:pubkey)
      wanted = (messages_scope.distinct.limit(500).pluck(:pubkey) - known).first(PROFILE_BATCH)
      return if wanted.empty?

      events = BuzzRelayClient.query([{ kinds: [0], authors: wanted, limit: wanted.size * 3 }])
      newest = events.select { |e| e.is_a?(Hash) && wanted.include?(e['pubkey']) && e['kind'] == 0 }
                     .group_by { |e| e['pubkey'] }.transform_values { |list| list.max_by { |e| e['created_at'].to_i } }
      now = Time.current
      rows = wanted.map do |pubkey|
        name, display = profile_names(newest[pubkey])
        { tenant_id: Current.tenant_id, pubkey: pubkey, name: name, display_name: display, fetched_at: now, created_at: now, updated_at: now }
      end
      BuzzProfile.upsert_all(rows, unique_by: :idx_buzz_profiles_pubkey, update_only: %i[name display_name fetched_at updated_at])
    rescue BuzzRelayClient::Error
      nil
    end

    def profile_names(event)
      return [nil, nil] unless event && event['content'].to_s.length <= 8000

      data = JSON.parse(event['content'])
      return [nil, nil] unless data.is_a?(Hash)

      [clean_name(data['name']), clean_name(data['display_name'] || data['displayName'])]
    rescue JSON::ParserError
      [nil, nil]
    end

    def clean_name(value)
      return nil unless value.is_a?(String)

      value.scrub('').gsub(CONTROL, '').gsub(/\s+/, ' ').strip.first(60).presence
    end

    # --- presenting ---

    def present_one(row, profile, agent, viewer)
      is_agent = agent.present? && row.pubkey == agent
      text = row.content
      name = profile&.label
      via_person = nil
      if is_agent && row.client == CLIENT_TAG && (m = text.match(/\A(.{1,60}?)#{Regexp.escape(VIA)}(.*)\z/m))
        via_person = clean_name(m[1])
        text = m[2]
      end
      {
        id: row.event_id, cursor: row.cursor, at: Time.zone.at(row.posted_at).iso8601, text: text, reply: row.reply_to.present?,
        author: via_person || name || (is_agent ? BuzzAgentPrompt::NAME : short_npub(row.pubkey)),
        key: short_npub(row.pubkey), agent: is_agent, via_rupert: via_person.present?, named: (via_person || name).present?,
        mine: viewer.present? && row.rupert_user_id == viewer.id
      }
    end

    # --- posting helpers ---

    def clean_post(text)
      clean = text.to_s.scrub('').gsub(CONTROL, '').strip
      raise Invalid, 'Type a message first.' if clean.blank?
      raise Invalid, "Please keep it under #{POST_MAX} characters." if clean.length > POST_MAX
      raise Invalid, 'That looks like a private key (nsec). Never post one; delete it and keep it secret.' if clean.match?(NSEC)

      clean
    end

    def sender_name(user)
      user.display_name.to_s.scrub('').gsub(CONTROL, '').gsub(/[:\n]/, ' ').gsub(/\s+/, ' ').strip.first(40).presence || 'Someone'
    end

    def enforce_rate_limit!(user)
      POST_LIMITS.each do |window, max|
        next if BuzzMessage.where(rupert_user_id: user.id).where(created_at: window.ago..).count < max

        raise RateLimited, 'You are posting quickly. Wait a moment and try again.'
      end
    end

    def store_posted(event, user)
      BuzzMessage.create!(
        event_id: event.id, pubkey: event.pubkey.to_s, kind: event.kind, channel: channel, content: clean_incoming(event.content),
        client: CLIENT_TAG, rupert_user_id: user.id, posted_at: event.created_at
      )
    rescue ActiveRecord::RecordNotUnique
      BuzzMessage.find_by(event_id: event.id)
    end
  end
end
