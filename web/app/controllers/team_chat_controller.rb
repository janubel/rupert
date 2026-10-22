# frozen_string_literal: true

# Team chat: Slack-style rooms inside Rupert, with @rupert answering from
# Rupert's own tools (docs/ops/team-chat.md). Administrators only for now.
#
# The page polls one JSON endpoint: new and changed messages since the last
# poll (so a reply being written, or an action someone approved, shows up),
# plus unread counts for the room list. Production runs SQLite without Redis,
# so polling local rows is the simplest thing that survives deploys.
class TeamChatController < AuthenticatedController
  PAGE = 50
  MEDIA_PAGE = 60
  CHANGED_MAX = 200

  before_action :require_access
  before_action -> { response.headers['Cache-Control'] = 'no-store' }, except: %i[index show]
  before_action :load_room, except: %i[index create_room create_dm dock unread scores presence presence_policy]

  # GET /chat — the last room you were in, else #general.
  def index
    general = TeamChat::Room.ensure_defaults!(Current.user)
    last = TeamChat::Membership.where(user_id: Current.user.id).order(updated_at: :desc).first&.room
    redirect_to team_chat_room_path(last&.visible_to?(Current.user) ? last : general)
  end

  # GET /chat/:room
  def show
    TeamChat::Room.ensure_defaults!(Current.user)
    @membership = @room.membership_for(Current.user)
    @membership.touch
    @rooms = rail_rooms
    @members = @room.direct? ? [Current.user] : @room.members.where(active: true).order(:id).limit(12).to_a
    @model = TeamChat::ModelConfig.current
    @local_agents = TeamChat::LocalAgents.all.map { |agent| { id: nil, name: agent.handle, label: agent.label } }
    @people = mentionable_people
  end

  # GET /chat/dock — the room list in the chat dock (a Turbo Frame on every page).
  def dock
    TeamChat::Room.ensure_defaults!(Current.user)
    @rooms = rail_rooms
    render layout: false
  end

  # GET /chat/:room/dock — one room, compact, inside the dock's frame.
  def dock_room
    @membership = @room.membership_for(Current.user)
    @membership.touch
    @model = TeamChat::ModelConfig.current
    @people = mentionable_people
    @local_agents = TeamChat::LocalAgents.all.map { |agent| { id: nil, name: agent.handle, label: agent.label } }
    render layout: false
  end

  # GET /chat/unread.json — totals for the header badge. Rooms you hid only count when they mention you.
  def unread
    rooms = rail_rooms
    render json: { unread: rooms.reject(&:hidden?).sum(&:unread), mentions: rooms.sum(&:mentions) }
  end

  # PATCH /chat/:room/visibility { hidden } — hide a room from your own list, or show it again.
  def visibility
    return head :forbidden if @room.direct?

    hidden = ActiveModel::Type::Boolean.new.cast(params[:hidden])
    @room.membership_for(Current.user).update!(hidden_at: hidden ? Time.current : nil)
    respond_to do |format|
      format.json { render json: { hidden: hidden } }
      format.html { redirect_to team_chat_room_path(@room), notice: hidden ? "##{@room.name} is hidden from your list. Find it under Hidden rooms." : "##{@room.name} is back in your list." }
    end
  end

  # GET /chat/:room/messages(.json)
  #   (none)        the latest page of the room
  #   before=<id>   an older page
  #   since=<cursor> messages created or changed since the last poll
  #   thread=<id>   also the whole thread under that message
  # Return now unchanged as the next since cursor; it may include a pagination
  # position when more than CHANGED_MAX messages changed (old time-only cursors
  # are still accepted).
  def messages
    cursor = change_cursor if params[:since].present?
    return render json: { error: 'Bad cursor.' }, status: :unprocessable_entity if params[:since].present? && !cursor

    expire_stale if cursor || params[:before].blank?
    # Capture the boundary before selecting rows, including the initial load.
    # A worker finishing during serialization must remain in the next window.
    through = Time.current
    next_cursor = through.iso8601(6)
    has_more_changes = false
    scope = @room.messages.includes(:user, :pinned_by, :attachment_infos, :ratings, reactions: :user)
    rows =
      if cursor
        changed, next_cursor, has_more_changes = changed_messages(scope, cursor, through: through)
        changed
      elsif params[:before].present?
        scope.visible.top_level.where(id: ...params[:before].to_i).order(id: :desc).limit(PAGE).to_a.reverse
      else
        scope.visible.top_level.order(id: :desc).limit(PAGE).to_a.reverse
      end
    has_more = params[:since].blank? && rows.size == PAGE
    rows |= thread_rows(scope) if params[:thread].present?
    if params[:visible] == '1'
      mark_read(rows)
      TeamChat::Presence.touch(Current.user)
    end
    render json: {
      now: next_cursor, messages: payload(rows), has_more: has_more, has_more_changes: has_more_changes, pins: pins, typing: typing_names, presence: presence_map,
      rooms: rail_rooms.map { |room| { slug: room.slug, unread: room.unread, mentions: room.mentions } }
    }
  end

  # POST /chat/:room/messages { body, parent_id }
  def create_message
    result = TeamChat::Post.call(room: @room, user: Current.user, body: params[:body], parent_id: params[:parent_id],
      files: params[:files], mention_ids: params[:mention_ids], quote_id: params[:quote_id])
    render json: { messages: payload([result.message, *result.replies].compact) }, status: :created
  rescue TeamChat::Post::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue TeamChat::Post::Limited => e
    render json: { error: e.message }, status: :too_many_requests
  end

  # PATCH /chat/presence { hidden } — show or hide your own "recently active".
  def presence
    Current.user.update_column(:presence_hidden, ActiveModel::Type::Boolean.new.cast(params[:hidden]) ? true : nil)
    render json: presence_settings
  end

  # PATCH /chat/presence/policy { everyone, roles: { role => choice|on|off|same } } — admins only.
  def presence_policy
    return render json: { error: 'Only administrators set the workspace rule.' }, status: :forbidden unless TeamChat::Presence.manage?(Current.user)

    roles = params[:roles].respond_to?(:to_unsafe_h) ? params[:roles].to_unsafe_h : {}
    TeamChat::Presence.save_policy!(everyone: params[:everyone], roles: roles)
    ActivityLogger.log('team_chat_presence_policy', actor: Current.user, details: TeamChat::Presence.policy.to_json.first(300))
    render json: presence_settings
  end

  # GET /chat/:room/files/:id — an attachment, only to people who can open the room.
  def attachment
    file = TeamChat::Attachment.where(room_id: @room.id).find(params[:id])
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox"
    response.headers['Cache-Control'] = 'private, max-age=86400'
    bytes = file.data || TeamChat::DriveStore.new.fetch(file)
    send_data bytes, type: file.content_type, filename: file.filename, disposition: file.image? || file.content_type == 'application/pdf' ? 'inline' : 'attachment'
  rescue TeamChat::DriveStore::Error, Google::Apis::Error, Signet::AuthorizationError => e
    Rails.logger.warn("[TeamChat::Drive] fetch failed: #{e.class}")
    render plain: 'This file is kept in Google Drive and could not be fetched right now. Try again in a moment.', status: :bad_gateway
  end

  # GET /chat/:room/media.json?q=&kind=all|images|files&before=<id>
  # The room's photos and files, newest first, searchable by file name, message text or poster.
  def media
    columns = (TeamChat::Attachment.column_names - ['data']).map { |name| "chat_attachments.#{name}" }
    scope = TeamChat::Attachment.select(columns).where(room_id: @room.id)
                                .joins(:message).where(chat_messages: { deleted_at: nil })
    scope = scope.where(content_type: TeamChat::Attachment::IMAGE_TYPES) if params[:kind] == 'images'
    scope = scope.where.not(content_type: TeamChat::Attachment::IMAGE_TYPES) if params[:kind] == 'files'
    scope = scope.where(id: ...params[:before].to_i) if params[:before].present?
    if (query = params[:q].to_s.strip.first(80)).present?
      like = "%#{TeamChat::Attachment.sanitize_sql_like(query.downcase)}%"
      scope = scope.joins('LEFT JOIN users ON users.id = chat_messages.user_id')
                   .where('LOWER(chat_attachments.filename) LIKE :q OR LOWER(chat_messages.body) LIKE :q OR LOWER(users.name) LIKE :q OR LOWER(users.email) LIKE :q', q: like)
    end
    rows = scope.preload(message: :user).order(id: :desc).limit(MEDIA_PAGE + 1).to_a
    items = rows.first(MEDIA_PAGE).map do |file|
      message = file.message
      file.as_payload(@room).merge(message_id: message.id, parent_id: message.parent_id, created_at: file.created_at.iso8601,
        author: message.author_name, email: (message.user&.email if message.person?), excerpt: message.body.to_s.squish.first(120))
    end
    render json: { items: items, has_more: rows.size > MEDIA_PAGE }
  end

  # POST /chat/:room/messages/:id/reactions { emoji } — adds or removes yours.
  def react
    message = @room.messages.visible.find(params[:id])
    return render json: { error: 'Pick one of the offered reactions.' }, status: :unprocessable_entity unless TeamChat::Reaction::EMOJI.include?(params[:emoji])

    TeamChat::Reaction.toggle!(message, Current.user, params[:emoji])
    render json: { messages: payload([message.reload]) }
  end

  # POST /chat/:room/messages/:id/rating { value: up|down } — thumbs on an assistant reply; the same choice again clears it.
  def rate
    message = @room.messages.visible.find(params[:id])
    return render json: { error: 'Only finished assistant replies can be rated.' }, status: :unprocessable_entity unless message.assistant? && message.status == 'done'
    return render json: { error: 'Choose up or down.' }, status: :unprocessable_entity unless TeamChat::Rating::VALUES.key?(params[:value].to_s)

    TeamChat::Rating.rate!(message, Current.user, params[:value])
    render json: { messages: payload([message.reload]) }
  end

  # POST /chat/:room/messages/:id/rating/reason { reason } — the optional "why" on your 👍/👎.
  def rating_reason
    message = @room.messages.visible.find(params[:id])
    rating = message.ratings.find_by(user_id: Current.user.id)
    return render json: { error: 'Rate the reply first.' }, status: :unprocessable_entity unless rating

    rating.note!(params[:reason])
    render json: { messages: payload([message.reload]) }
  end

  # POST /chat/:room/messages/:id/pin — pins (or unpins) a message as the room's banner.
  def pin
    message = @room.messages.visible.where.not(status: 'pending').find(params[:id])
    return head :unprocessable_entity if message.system?

    notice = message.toggle_pin!(Current.user)
    ActivityLogger.log('team_chat_pin', details: "room=#{@room.slug}; message=#{message.id}; pinned=#{message.pinned?}")
    render json: { messages: payload([message.reload, notice].compact), pins: pins }
  end

  # GET /chat/models — which models people like, and how fast and reliable each is.
  def scores
    @days = params[:days].present? ? params[:days].to_i.clamp(1, 365) : 30
    @rows = TeamChat::ModelScores.call(since: @days.days.ago)
    @slow = TeamChat::ModelScores.slow(since: @days.days.ago).select { |row| row.room&.visible_to?(Current.user) }
    @notes = TeamChat::Rating.where.not(reason: [nil, '']).where(created_at: @days.days.ago..).includes(:user).order(updated_at: :desc).limit(30)
    @current = TeamChat::ModelConfig.current
    @run_sets = TeamChat::BatteryRun.distinct.order(:set_name).pluck(:set_name)
    @run_set = @run_sets.include?(params[:set].to_s) ? params[:set].to_s : nil
    runs = TeamChat::BatteryRun.newest_first
    runs = runs.where(set_name: @run_set) if @run_set
    @runs = runs.limit(60).to_a
    @leaderboard = TeamChat::Leaderboard.call
  end

  # PATCH /chat/:room/messages/:id { body } — edit your own message.
  def update_message
    message = @room.messages.visible.find(params[:id])
    return head :forbidden unless message.person? && message.user_id == Current.user.id

    message.edit_body!(params[:body])
    render json: { messages: payload([message.reload]) }
  rescue ActiveRecord::RecordInvalid
    render json: { error: 'A message needs some text.' }, status: :unprocessable_entity
  end

  # POST /chat/:room/typing — "you are typing" heartbeat, shown to the others for a few seconds.
  def typing
    @room.membership_for(Current.user).typing!
    head :no_content
  end

  # POST /chat/dms { user_id } — open (or start) a direct message with someone.
  def create_dm
    other = User.find_by(id: params[:user_id], tenant_id: Current.tenant_id, active: true)
    return redirect_to(team_chat_path, alert: 'That person cannot use team chat.') unless other && TeamChat.allowed?(other) && other.id != Current.user.id

    redirect_to team_chat_room_path(TeamChat::Room.dm_between(Current.user, other))
  end

  # DELETE /chat/:room/messages/:id — your own messages only.
  def destroy_message
    message = @room.messages.find(params[:id])
    return head :forbidden unless message.person? && message.user_id == Current.user.id

    message.soft_delete!
    render json: { messages: payload([message]) }
  end

  # POST /chat/:room/messages/:id/actions/:action_id { decision: approve|dismiss }
  def decide
    message = @room.messages.find(params[:id])
    TeamChat::Actions.decide!(message, params[:action_id], user: Current.user, approve: params[:decision] == 'approve')
    render json: { messages: payload([message.reload]) }
  rescue TeamChat::Actions::Denied => e
    render json: { error: e.message }, status: :forbidden
  end

  # POST /chat/rooms { name, topic, assistant_mode }
  def create_room
    room = TeamChat::Room.create!(room_params.merge(kind: 'channel', created_by: Current.user))
    room.membership_for(Current.user)
    ActivityLogger.log('team_chat_room_created', details: "room=#{room.slug}")
    redirect_to team_chat_room_path(room)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to team_chat_path, alert: "The room was not created: #{e.record.errors.full_messages.to_sentence}."
  end

  # PATCH /chat/:room { topic, assistant_mode, archived }
  def update_room
    return head :forbidden unless @room.channel?

    attributes = room_params.slice(:assistant_mode)
    attributes[:topic] = params[:topic].to_s.strip.presence if params.key?(:topic)
    attributes[:archived_at] = Time.current if ActiveModel::Type::Boolean.new.cast(params[:archived]) && @room.slug != TeamChat::Room::MAIN_SLUG
    @room.update!(attributes)
    ActivityLogger.log('team_chat_room_updated', details: "room=#{@room.slug}; fields=#{attributes.keys.join(',')}")
    respond_to do |format|
      format.json { render json: { ok: true, assistant_mode: @room.assistant_mode, topic: @room.topic } }
      format.html { redirect_to(@room.archived? ? team_chat_path : team_chat_room_path(@room)) }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  private

  def require_access
    return head :forbidden unless TeamChat.allowed?(Current.user)

    authorize(:module, :dashboard_read?)
  end

  def load_room
    slug = params[:room].to_s
    @room = TeamChat::Room.find_by(slug: slug)
    # Old links (and saved dock state) to #general now open #admins.
    @room ||= TeamChat::Room.find_by(slug: TeamChat::Room::MAIN_SLUG) if slug == 'general'
    head :not_found unless @room&.visible_to?(Current.user)
  end

  def room_params
    params.permit(:name, :topic, :assistant_mode).to_h.symbolize_keys.compact_blank
  end

  def typing_names
    @room.memberships.where(typing_at: TeamChat::Membership::TYPING_FOR.ago..).where.not(user_id: Current.user.id)
         .includes(:user).filter_map { |row| row.user&.display_name }
  end

  def pins
    @room.messages.visible.pinned.includes(:user, :pinned_by, :attachment_infos).order(pinned_at: :desc).limit(TeamChat::Message::PINS_SHOWN).map(&:pin_payload)
  end

  # Who is active now (or was within the hour), for everyone who uses team chat.
  def presence_map
    TeamChat::Presence.statuses(TeamChat::Post.mentionable).transform_keys(&:to_s)
  end

  def presence_settings
    rules = TeamChat::Presence.policy
    mode = TeamChat::Presence.mode_for(Current.user, rules)
    { hidden: Current.user.presence_hidden == true, mode: mode, shown: TeamChat::Presence.shown?(Current.user, rules), policy: rules, presence: presence_map }
  end

  def mentionable_people
    TeamChat::Post.mentionable.reject { |person| person.id == Current.user.id }.map { |person| { id: person.id, name: person.display_name, email: person.email } }
  end

  def rail_rooms
    @rail_rooms ||= begin
      rooms = TeamChat::Room.visible_to(Current.user).order(:kind, :name).to_a
      memberships = TeamChat::Membership.where(user_id: Current.user.id, room_id: rooms.map(&:id)).pluck(:room_id, :last_read_message_id, :hidden_at)
      reads = memberships.to_h { |room_id, last_read, _| [room_id, last_read] }
      hidden = memberships.filter_map { |room_id, _, hidden_at| room_id if hidden_at }.to_set
      me = Current.user.id
      rooms.each do |room|
        room.define_singleton_method(:hidden?) { hidden.include?(room.id) }
        unread = room.messages.visible.where('id > ?', reads[room.id].to_i).where('user_id IS NULL OR user_id != ?', me).where.not(status: 'pending')
        room.define_singleton_method(:unread) { unread.top_level.count }
        # Mentions count in threads too; the JSON column holds a plain id list.
        room.define_singleton_method(:mentions) { unread.where('mentions LIKE ? OR mentions LIKE ? OR mentions LIKE ? OR mentions = ?', "[#{me},%", "%,#{me},%", "%,#{me}]", "[#{me}]").count }
      end
    end
  end

  def thread_rows(scope)
    root = scope.find_by(id: params[:thread].to_i, parent_id: nil)
    root ? [root, *scope.where(parent_id: root.id).order(:id).to_a] : []
  end

  def change_cursor
    timestamp, id, *extra = params[:since].to_s.split('|', -1)
    return if extra.any? || (id && (!id.match?(/\A[1-9]\d*\z/) || id.to_i > 9_223_372_036_854_775_807))

    [Time.iso8601(timestamp), id&.to_i]
  rescue ArgumentError
    nil
  end

  def changed_messages(scope, cursor, through:)
    since, after_id = cursor
    changed = scope.where(updated_at: since..through)
    if after_id
      changed = changed.where('chat_messages.updated_at > :since OR chat_messages.id > :id', since: since, id: after_id)
    end
    rows = changed.order(:updated_at, :id).limit(CHANGED_MAX + 1).to_a
    more = rows.size > CHANGED_MAX
    rows.pop if more
    # Only advance past delivered rows. The ID breaks timestamp ties, so an
    # offline tab can drain a large backlog instead of skipping or repeating it.
    next_cursor = more ? "#{rows.last.updated_at.iso8601(6)}|#{rows.last.id}" : through.iso8601(6)
    [rows, next_cursor, more]
  end

  def payload(rows)
    roots = rows.map { |row| row.parent_id || row.id }.uniq
    counts = @room.messages.visible.where(parent_id: roots).group(:parent_id).count
    ids = rows.flat_map(&:mention_ids).uniq
    people = ids.any? ? User.where(id: ids, tenant_id: Current.tenant_id).to_h { |user| [user.id, user.display_name] } : {}
    quote_ids = rows.filter_map(&:quote_id).uniq
    quotes = quote_ids.any? ? @room.messages.includes(:user, :attachment_infos).where(id: quote_ids).index_by(&:id) : {}
    rows.sort_by(&:id).map { |row| row.as_payload(viewer: Current.user, reply_counts: counts, people: people, quotes: quotes) }
  end

  def mark_read(rows)
    latest = rows.select { |row| row.parent_id.nil? }.map(&:id).max
    @room.membership_for(Current.user).mark_read!(latest) if latest
  end

  def expire_stale
    @room.messages.pending.where(created_at: ...TeamChat::Message::STALE_AFTER.ago).find_each do |row|
      row.update!(status: 'failed', activity: nil, body: TeamChat::Agent::FAILURES[:error])
    end
  end
end
