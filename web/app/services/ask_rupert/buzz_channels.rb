# frozen_string_literal: true

module AskRupert
  # Which Buzz channels the agent is in and who is in them, learned from the
  # relay's member-list events (kind 39002: the channel id in `d`, its type in the
  # first `t`, a `p` per member). Used only to tell a one-to-one direct message
  # from a room. Anything not known to be a one-to-one message is a room, which
  # is the cautious answer.
  class BuzzChannels
    Channel = Struct.new(:id, :type, :members, keyword_init: true)

    MEMBER_LIST = 39_002
    ADDED = 44_100
    REMOVED = 44_101
    GROUP_KINDS = [MEMBER_LIST, ADDED, REMOVED].freeze
    CHANNEL_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    def initialize(agent_pubkey)
      @agent = agent_pubkey.to_s.downcase
      @channels = {}
      @asked = []
    end

    # Takes in one group event. Returns true when the set of channels changed
    # (so the agent should subscribe again).
    def observe(event)
      case event['kind'].to_i
      when MEMBER_LIST then record(event)
      when ADDED then note_added(event)
      when REMOVED then forget(tag(event, 'h'))
      else false
      end
    end

    def ids = @channels.keys

    # :dm when the channel is a direct message between the agent and exactly this sender, else :room.
    def kind_for(channel_id, sender)
      channel = @channels[channel_id.to_s]
      return :room unless channel && channel.type == 'dm'

      members = channel.members
      members.size == 2 && members.include?(@agent) && members.include?(sender.to_s.downcase) ? :dm : :room
    end

    private

    def record(event)
      id = tag(event, 'd')
      return false unless id&.match?(CHANNEL_ID)

      members = Array(event['tags']).filter_map { |item| item[1].to_s.downcase if item[0] == 'p' }.uniq
      return forget(id) unless members.include?(@agent)

      known = @channels.key?(id)
      @channels[id] = Channel.new(id: id, type: tag(event, 't'), members: members)
      !known
    end

    # An add notice only tells us to look again; the member list says what the channel is.
    def note_added(event)
      id = tag(event, 'h')
      return false unless tag(event, 'p').to_s.downcase == @agent && id&.match?(CHANNEL_ID) && !@channels.key?(id)

      # Once per channel, so a notice replayed by the relay cannot make the agent ask again and again.
      @asked.include?(id) ? false : (@asked << id) && true
    end

    def forget(id)
      !@channels.delete(id.to_s).nil?
    end

    def tag(event, name)
      Array(event['tags']).find { |item| item[0] == name }&.at(1)
    end
  end
end
