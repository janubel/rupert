# frozen_string_literal: true

# The Team chat tab on the Buzz page: the workspace's channels, recent
# messages, live updates by polling, scrollback and a composer. Reading needs
# buzz.read and posting needs buzz.post (administrators by default; delegable
# on the Permissions screen). Messages are other people's text and are returned
# as plain strings for the page to show as text. Posts go out as the Rupert
# agent with the sender's name in front, so the relay never sees a per-person
# key (see BuzzChat).
class BuzzChatController < AuthenticatedController
  before_action :require_read
  before_action :require_post, only: %i[create typing]
  before_action -> { response.headers['Cache-Control'] = 'no-store' }, except: :show

  # GET /buzz/chat
  def show
    @state = BuzzChat.state
    @channels = BuzzChannels.list
    @channel = selected_channel
    @members = BuzzMembers.roster(@channel)
    @member_overflow = BuzzMembers.extra_count(@channel)
    @can_post = Current.user.can?('buzz.post')
    @can_configure = Current.user.can?('settings.write')
    @chat_base_path = buzz_chat_path
  end

  # GET /buzz/chat/messages(.json) — ?channel=<id>, ?before=<cursor> for
  # scrollback, ?after=<cursor> for new messages.
  def messages
    before = BuzzMessage.parse_cursor(params[:before]) if params[:before].present?
    after = BuzzMessage.parse_cursor(params[:after]) if params[:after].present?
    return render json: { error: 'Bad cursor.' }, status: :unprocessable_entity if (params[:before].present? && before.nil?) || (params[:after].present? && after.nil?)

    channel = selected_channel
    keep_fresh(channel) unless before
    page = BuzzChat.page(before: before, after: after, viewer: Current.user, channel: channel.id)
    render json: page.merge(status: status_json, channel: { id: channel.id, name: channel.name }, typing: typing_json(channel))
  end

  # POST /buzz/chat/typing { channel: "...", reply_to: "..." } — the person is
  # typing; sent on as their own Buzz identity, at most every few seconds.
  def typing
    channel = selected_channel
    key = "buzz_typing_sent/#{Current.user.id}/#{channel.id}"
    unless Rails.cache.read(key)
      Rails.cache.write(key, true, expires_in: 3.seconds)
      BuzzChat.typing!(user: Current.user, channel: channel.id, reply_to: params[:reply_to].presence)
    end
    head :no_content
  end

  # POST /buzz/chat/messages { message: "...", channel: "..." }
  def create
    channel = selected_channel
    text = params[:message].to_s
    row = BuzzChat.post!(user: Current.user, text: text, channel: channel.id, reply_to: params[:reply_to].presence)
    render json: { ok: true, event_id: row&.event_id }, status: :created
  rescue BuzzChat::NotMember => e
    render json: { error: e.message }, status: :conflict
  rescue BuzzChat::RateLimited
    render json: { error: 'You are posting quickly. Wait a moment and try again.' }, status: :too_many_requests
  rescue BuzzChat::Error => e
    render json: { error: e.message }, status: (e.is_a?(BuzzChat::PostFailed) ? :bad_gateway : :unprocessable_entity)
  end

  private

  def require_read
    return head :forbidden if Current.user.employee? || !Current.user.can?('buzz.read') || Current.tenant_id != Current.user.tenant_id

    authorize(:module, :dashboard_read?)
  end

  def require_post
    head :forbidden unless Current.user.can?('buzz.post')
  end

  # Only channels the Rupert agent can see are selectable; anything else falls
  # back to the configured channel. This keeps arbitrary relay group ids from
  # being used as a read oracle.
  def selected_channel
    return @selected_channel if defined?(@selected_channel)

    requested = params[:channel].to_s
    @selected_channel =
      if @channels
        @channels.find { |channel| channel.id == requested } ||
          @channels.find { |channel| channel.id == BuzzAgent.channel_id } ||
          @channels.first || BuzzChannels.fallback
      else
        BuzzChannels.find(requested) || BuzzChannels.default || BuzzChannels.fallback
      end
  end

  # The first look fills the copy right away; after that a background job brings
  # it up to date, at most every few seconds however many pages are open.
  def keep_fresh(channel)
    return unless BuzzChat.ready?
    return unless BuzzChatState.claim_attempt!

    if BuzzChat.empty_cache?(channel: channel.id)
      BuzzChat.sync!(channel: channel.id)
    else
      BuzzChatSyncJob.perform_later(Current.tenant_id, channel.id)
    end
  end

  # People typing in this channel now (not the viewer), from the live
  # subscription BuzzTyping keeps while the page is open.
  def typing_json(channel)
    channels = (BuzzChannels.cached || []).map(&:id) | [channel.id]
    BuzzTyping.watch!(Current.tenant_id, channels)
    mine = BuzzPersonKey.find_by(user_id: Current.user.id)&.pubkey
    agent = BuzzChat.agent_pubkey
    BuzzTyping.current(Current.tenant_id, channel.id).filter_map do |entry|
      next if entry[:pubkey] == mine

      { name: BuzzChat.display_name(entry[:pubkey]), agent: entry[:pubkey] == agent, thread: entry[:thread] }
    end
  rescue StandardError => e
    Rails.logger.info("[BuzzChat] typing unavailable: #{e.class}")
    []
  end

  def status_json
    status = BuzzChat.status
    { state: status[:state], synced_at: status[:synced_at]&.iso8601, error: status[:error], can_post: Current.user.can?('buzz.post'),
      post_max: BuzzChat::POST_MAX }
  end
end
