# frozen_string_literal: true

require 'test_helper'

class TeamChatTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def sign_in(user, password: 'password')
    post login_path, params: { email: user.email, password: password }
  end

  def json = response.parsed_body

  def manager
    @manager ||= User.create!(tenant: @tenant, email: 'chat-manager@example.com', role: 'manager', password: 'password123', name: 'Mo Manager')
  end

  test 'signed-out visitors are sent to sign in' do
    get team_chat_path
    assert_redirected_to login_path
  end

  test 'people without administrator access cannot open it' do
    sign_in(manager, password: 'password123')
    get team_chat_path
    assert_response :forbidden
  end

  test 'it opens #general with a direct room for Rupert and appears in navigation' do
    sign_in(@admin)
    get team_chat_path
    assert_redirected_to team_chat_room_path('general')
    follow_redirect!
    assert_response :success
    assert_select '[data-controller="team-chat"]'
    assert_select '.chat-rail-room', text: /general/
    assert_select ".chat-rail-room[href='#{team_chat_room_path("rupert-#{@admin.id}")}']"
    assert_includes ModuleRegistry.nav_for(@admin).map(&:key), 'team_chat'
  end

  test 'posting, mentioning @rupert and polling' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: 'Good morning' }, as: :json
    assert_response :created
    assert_equal 1, json['messages'].size

    assert_enqueued_with(job: TeamChat::ReplyJob) do
      post team_chat_messages_path('general'), params: { body: '@rupert how were sales yesterday?' }, as: :json
    end
    assert_response :created
    person, reply = json['messages']
    assert_equal 'person', person['kind']
    assert_equal 'assistant', reply['kind']
    assert_equal 'pending', reply['status']

    get team_chat_messages_path('general'), as: :json
    assert_equal ['Good morning', '@rupert how were sales yesterday?', ''], json['messages'].pluck('body')
    since = json['now']

    travel 2.seconds
    TeamChat::Message.find(reply['id']).update!(body: 'Sales were fine.', status: 'done')
    get team_chat_messages_path('general', since: since), as: :json
    assert_equal ['Sales were fine.'], json['messages'].pluck('body')
  end

  test 'empty and oversized messages are refused' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: '  ' }, as: :json
    assert_response :unprocessable_entity
    post team_chat_messages_path('general'), params: { body: 'x' * (TeamChat::Message::BODY_MAX + 1) }, as: :json
    assert_response :unprocessable_entity
  end

  test 'thread replies stay out of the main page but come with their thread' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: 'Root' }, as: :json
    root = json['messages'].first['id']
    post team_chat_messages_path('general'), params: { body: 'In thread', parent_id: root }, as: :json
    get team_chat_messages_path('general'), as: :json
    assert_equal ['Root'], json['messages'].pluck('body')
    assert_equal 1, json['messages'].first['reply_count']
    get team_chat_messages_path('general', thread: root), as: :json
    assert_equal %w[Root In\ thread], json['messages'].pluck('body')
  end

  test 'someone else’s direct room with Rupert is private' do
    other = User.create!(tenant: @tenant, email: 'other-admin@example.com', role: 'admin', password: 'password123', name: 'Ola Admin')
    room = TeamChat::Room.direct_for(other)
    sign_in(@admin)
    get team_chat_room_path(room)
    assert_response :not_found
    get team_chat_messages_path(room), as: :json
    assert_response :not_found
  end

  test 'you can delete only your own messages' do
    sign_in(@admin)
    get team_chat_path
    room = TeamChat::Room.find_by(slug: 'general')
    theirs = room.messages.create!(user: manager, body: 'Not yours')
    delete team_chat_message_path('general', theirs.id), as: :json
    assert_response :forbidden
    post team_chat_messages_path('general'), params: { body: 'Mine' }, as: :json
    delete team_chat_message_path('general', json['messages'].first['id']), as: :json
    assert_response :success
    assert json['messages'].first['deleted']
  end

  test 'rooms can be created, set to answer every message, and archived' do
    sign_in(@admin)
    post team_chat_rooms_path, params: { name: 'Inventory Team', topic: 'Counts' }
    assert_redirected_to team_chat_room_path('inventory-team')
    patch team_chat_room_path('inventory-team'), params: { assistant_mode: 'all' }, as: :json
    assert_equal 'all', json['assistant_mode']
    assert_enqueued_with(job: TeamChat::ReplyJob) do
      post team_chat_messages_path('inventory-team'), params: { body: 'what is low?' }, as: :json
    end
    patch team_chat_room_path('inventory-team'), params: { archived: true }
    assert_redirected_to team_chat_path
    get team_chat_room_path('inventory-team')
    assert_response :not_found
  end

  test 'unread counts follow what you have read' do
    sign_in(@admin)
    get team_chat_path
    room = TeamChat::Room.find_by(slug: 'general')
    room.messages.create!(user: manager, body: 'one')
    room.messages.create!(user: manager, body: 'two')
    get team_chat_messages_path(TeamChat::Room.direct_for(@admin)), as: :json
    assert_equal 2, json['rooms'].find { |row| row['slug'] == 'general' }['unread']
    get team_chat_messages_path('general', visible: 1), as: :json
    assert_equal 0, json['rooms'].find { |row| row['slug'] == 'general' }['unread']
  end

  PNG = "\x89PNG\r\n\x1A\n".b + ('x' * 64)

  def upload(bytes, name, type)
    file = Tempfile.new(['chat', File.extname(name)])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, true, original_filename: name)
  end

  test 'images and files are posted, served only to the room, and judged by their bytes' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: '', files: [upload(PNG, 'shelf.png', 'image/png'), upload("a,b\n1,2\n", 'counts.csv', 'text/csv')] }
    assert_response :created
    files = json['messages'].first['attachments']
    assert_equal %w[image/png text/csv], files.pluck('type')
    assert files.first['image']

    get files.first['url']
    assert_response :success
    assert_equal 'image/png', response.media_type
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    assert_match(/sandbox/, response.headers['Content-Security-Policy'])

    post team_chat_messages_path('general'), params: { body: 'x', files: [upload('<html><script>alert(1)</script>', 'evil.png', 'image/png')] }
    assert_response :unprocessable_entity
    assert_match(/not a supported file/, json['error'])

    other = User.create!(tenant: @tenant, email: 'other2@example.com', role: 'admin', password: 'password123', name: 'Ola Admin')
    direct = TeamChat::Room.direct_for(other)
    secret = direct.messages.new(user: other, body: 'private')
    secret.attachments.build(room: direct, filename: 'p.png', content_type: 'image/png', byte_size: PNG.bytesize, data: PNG)
    secret.save!
    get team_chat_attachment_path('general', secret.attachments.first.id)
    assert_response :not_found
  end

  test 'mentions are kept only for people named in the text, and show as unread mentions' do
    alex = User.create!(tenant: @tenant, email: 'alex@example.com', role: 'admin', password: 'password123', name: 'Alex Rivera')
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: '@Alex Rivera can you count?', mention_ids: [alex.id, manager.id] }
    assert_response :created
    message = json['messages'].first
    assert_equal [{ 'id' => alex.id, 'name' => 'Alex Rivera' }], message['mentions']

    delete logout_path
    sign_in(alex, password: 'password123')
    get team_chat_messages_path(TeamChat::Room.direct_for(alex)), as: :json
    row = json['rooms'].find { |room| room['slug'] == 'general' }
    assert_equal 1, row['mentions']
    get team_chat_messages_path('general'), as: :json
    assert json['messages'].last['mentions_me']
  end

  test 'reactions toggle and only offered emoji are accepted' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: 'Done!' }, as: :json
    id = json['messages'].first['id']
    post team_chat_reactions_path('general', id), params: { emoji: '🎉' }, as: :json
    assert_equal [{ 'emoji' => '🎉', 'count' => 1, 'mine' => true, 'names' => [@admin.display_name] }], json['messages'].first['reactions']
    post team_chat_reactions_path('general', id), params: { emoji: '🎉' }, as: :json
    assert_empty json['messages'].first['reactions']
    post team_chat_reactions_path('general', id), params: { emoji: '💩' }, as: :json
    assert_response :unprocessable_entity
  end

  test 'old Buzz addresses lead to team chat' do
    %w[/admin/buzz /buzz /buzz/chat].each do |path|
      get path
      assert_redirected_to '/chat', path
    end
  end

  test 'every page has a header chat button and a dock that lists rooms and opens one compactly' do
    sign_in(@admin)
    get root_path
    assert_select "a.chat-dock-trigger[href='#{team_chat_path}'][data-action~='click->chat-dock#toggle']"
    assert_select '#chat-dock-panel[data-turbo-permanent][hidden] turbo-frame#chat_dock'

    get team_chat_dock_path
    assert_response :success
    assert_select 'turbo-frame#chat_dock'
    assert_select "turbo-frame#chat_dock a.chat-dock-room[href='#{team_chat_dock_room_path('general')}']"
    assert_select "turbo-frame#chat_dock a[href='#{team_chat_path}'][data-turbo-frame='_top']"
    assert_no_match(/<html/, response.body)

    get team_chat_dock_room_path('general')
    assert_response :success
    assert_select "turbo-frame#chat_dock [data-controller='team-chat'][data-team-chat-compact-value='true']"
    assert_select "turbo-frame#chat_dock a[href='#{team_chat_room_path('general')}'][data-turbo-frame='_top']"
    assert_select 'turbo-frame#chat_dock textarea.chat-input'
  end

  test 'the full chat page has the button but no dock' do
    sign_in(@admin)
    get team_chat_room_path(TeamChat::Room.ensure_defaults!(@admin))
    assert_select 'a.chat-dock-trigger'
    assert_select '#chat-dock-panel', count: 0
  end

  test 'the header badge counts unread messages and mentions across rooms' do
    sign_in(@admin)
    get team_chat_path
    room = TeamChat::Room.find_by(slug: 'general')
    room.messages.create!(user: manager, body: 'one')
    room.messages.create!(user: manager, body: "@#{@admin.display_name} two", mentions: [@admin.id])
    get team_chat_unread_path, as: :json
    assert_equal({ 'unread' => 2, 'mentions' => 1 }, response.parsed_body)
  end

  test 'people without team chat get no button, dock or dock endpoints' do
    sign_in(manager, password: 'password123')
    get root_path
    assert_select 'a.chat-dock-trigger', count: 0
    assert_select '#chat-dock-panel', count: 0
    get team_chat_dock_path
    assert_response :forbidden
    get team_chat_unread_path, as: :json
    assert_response :forbidden
  end

  test 'assistant replies can be rated up or down once per person, and Model scores compares models' do
    sign_in(@admin)
    get team_chat_path
    room = TeamChat::Room.find_by(slug: 'general')
    person = room.messages.create!(user: @admin, body: 'question')
    qwen = room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Answer A',
      meta: { 'asked_by' => @admin.id, 'trigger_id' => person.id, 'engine' => 'local_gateway', 'model' => 'qwen3.5-4b', 'duration_ms' => 40_000, 'tools' => ['sales_summary'] })
    gemma = room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Answer B',
      meta: { 'asked_by' => @admin.id, 'trigger_id' => person.id, 'agent' => 'gemma', 'engine' => 'local_gateway', 'model' => 'gemma-4-e4b', 'duration_ms' => 80_000 })

    post team_chat_rating_path('general', qwen.id), params: { value: 'up' }, as: :json
    assert_equal({ 'up' => 1, 'down' => 0, 'mine' => 'up' }, json['messages'].first['rating'])
    post team_chat_rating_path('general', qwen.id), params: { value: 'down' }, as: :json
    assert_equal({ 'up' => 0, 'down' => 1, 'mine' => 'down' }, json['messages'].first['rating'])
    post team_chat_rating_path('general', qwen.id), params: { value: 'down' }, as: :json
    assert_equal({ 'up' => 0, 'down' => 0, 'mine' => nil }, json['messages'].first['rating'])
    assert_equal 0, TeamChat::Rating.count

    post team_chat_rating_path('general', qwen.id), params: { value: 'up' }, as: :json
    post team_chat_rating_path('general', gemma.id), params: { value: 'down' }, as: :json
    rating = TeamChat::Rating.find_by(message_id: gemma.id)
    assert_equal %w[gemma gemma-4-e4b local_gateway], [rating.agent, rating.model, rating.engine]

    post team_chat_rating_path('general', person.id), params: { value: 'up' }, as: :json
    assert_response :unprocessable_entity
    post team_chat_rating_path('general', qwen.id), params: { value: 'meh' }, as: :json
    assert_response :unprocessable_entity

    get team_chat_messages_path('general'), as: :json
    assert_nil json['messages'].find { |row| row['id'] == person.id }['rating']

    get team_chat_scores_path
    assert_response :success
    rows = css_select('tbody tr').map { |row| row.css('td').map { |cell| cell.text.squish } }
    assert_equal ['@rupert · qwen3.5-4b local gateway', '100%', '1', '0', '1', '0', '40.0 s', '40.0 s', '1.0'], rows.first
    assert_equal '@gemma · gemma-4-e4b local gateway', rows.second.first
    assert_equal '0%', rows.second.second
  end

  test 'Model scores is for team chat users only' do
    sign_in(manager, password: 'password123')
    get team_chat_scores_path
    assert_response :forbidden
  end

  test 'messages and thread replies can be pinned; the newest pin leads the banner list' do
    sign_in(@admin)
    get team_chat_path
    room = TeamChat::Room.find_by(slug: 'general')
    first = room.messages.create!(user: manager, body: 'Count the tea wall tonight after close.')
    reply = room.messages.create!(user: manager, body: 'Bring the scanner.', parent_id: first.id)

    post team_chat_pin_path('general', first.id), as: :json
    assert_response :success
    assert json['messages'].first['pinned']
    assert_equal @admin.display_name, json['messages'].first['pinned_by']
    notice = json['messages'].last
    assert_equal 'system', notice['kind']
    assert_match(/pinned a message from Mo Manager: “Count the tea wall/, notice['body'])

    travel 1.second
    post team_chat_pin_path('general', reply.id), as: :json
    assert_equal [reply.id, first.id], json['pins'].pluck('id')
    assert_equal first.id, json['pins'].first['parent_id']

    get team_chat_messages_path('general'), as: :json
    assert_equal [reply.id, first.id], json['pins'].pluck('id')

    assert_no_difference -> { room.messages.where(author_kind: 'system').count }, 'unpinning posts no notice' do
      post team_chat_pin_path('general', reply.id), as: :json
    end
    assert_not json['messages'].first['pinned']
    assert_equal [first.id], json['pins'].pluck('id')
  end

  test 'deleting a pinned message unpins it, and notices cannot be pinned' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: 'Pin me' }, as: :json
    id = json['messages'].first['id']
    post team_chat_pin_path('general', id), as: :json
    notice_id = json['messages'].last['id']
    delete team_chat_message_path('general', id), as: :json
    get team_chat_messages_path('general'), as: :json
    assert_empty json['pins']
    post team_chat_pin_path('general', notice_id), as: :json
    assert_response :unprocessable_entity
  end

  test 'both room views carry the pin banner' do
    sign_in(@admin)
    get team_chat_room_path(TeamChat::Room.ensure_defaults!(@admin))
    assert_select '.chat-pins[data-team-chat-target=pins][hidden]'
    get team_chat_dock_room_path('general')
    assert_select 'turbo-frame#chat_dock .chat-pins[data-team-chat-target=pins]'
  end

  def other_admin
    @other_admin ||= User.create!(tenant: @tenant, email: 'jo-admin@example.com', role: 'admin', password: 'password123', name: 'Jo Park')
  end

  test '#general holds every team chat user, and Rupert is listed with them' do
    other_admin
    sign_in(@admin)
    get team_chat_path
    follow_redirect!
    general = TeamChat::Room.find_by(slug: 'general')
    assert_includes general.members, other_admin
    assert_includes general.members, @admin
    assert_not_includes general.members, manager
    assert_select '.chat-member-avatar.is-bot[title=Rupert]'
  end

  test 'direct messages between two people are private to them' do
    sign_in(@admin)
    get team_chat_path
    post team_chat_dms_path, params: { user_id: other_admin.id }
    room = TeamChat::Room.find_by(kind: 'dm')
    assert_redirected_to team_chat_room_path(room)
    assert_equal [@admin.id, other_admin.id].sort, room.members.pluck(:id).sort
    post team_chat_dms_path, params: { user_id: other_admin.id }
    assert_equal 1, TeamChat::Room.where(kind: 'dm').count, 'the same pair reuses its room'

    follow_redirect!
    assert_select '.chat-head-title h2', /Jo Park/
    assert_select "a.chat-rail-room[href='#{team_chat_room_path(room)}']", /Jo Park/

    third = User.create!(tenant: @tenant, email: 'third-admin@example.com', role: 'admin', password: 'password123', name: 'Tia Third')
    post team_chat_messages_path(room), params: { body: '@Tia Third look', mention_ids: [third.id] }
    assert_response :created
    assert_not room.reload.members.include?(third), 'mentions never pull people into a DM'

    delete logout_path
    sign_in(third, password: 'password123')
    get team_chat_room_path(room)
    assert_response :not_found
    post team_chat_dms_path, params: { user_id: manager.id }
    assert_redirected_to team_chat_path
  end

  test 'typing shows to others for a few seconds and stops when the message is sent' do
    sign_in(@admin)
    get team_chat_path
    room = TeamChat::Room.find_by(slug: 'general')
    room.membership_for(other_admin).update!(typing_at: Time.current)
    post team_chat_typing_path('general')
    assert_response :no_content
    get team_chat_messages_path('general'), as: :json
    assert_equal ['Jo Park'], json['typing']
    post team_chat_messages_path('general'), params: { body: 'sent' }, as: :json
    assert_nil room.membership_for(@admin).reload.typing_at
    travel 10.seconds
    get team_chat_messages_path('general'), as: :json
    assert_empty json['typing']
  end

  test 'you can edit your own messages only; edits are marked and drop stale mentions' do
    other_admin
    sign_in(@admin)
    get team_chat_path
    post team_chat_messages_path('general'), params: { body: '@Jo Park count shelf 3', mention_ids: [other_admin.id] }, as: :json
    id = json['messages'].first['id']
    patch team_chat_message_path('general', id), params: { body: 'Count shelf 4 please' }, as: :json
    assert_response :success
    edited = json['messages'].first
    assert_equal 'Count shelf 4 please', edited['body']
    assert edited['edited']
    assert_empty edited['mentions']
    patch team_chat_message_path('general', id), params: { body: '  ' }, as: :json
    assert_response :unprocessable_entity

    theirs = TeamChat::Room.find_by(slug: 'general').messages.create!(user: other_admin, body: 'mine')
    patch team_chat_message_path('general', theirs.id), params: { body: 'hacked' }, as: :json
    assert_response :forbidden
  end

  test 'room views carry the typing line, the DM picker and the full-width layout' do
    other_admin
    sign_in(@admin)
    get team_chat_room_path(TeamChat::Room.ensure_defaults!(@admin))
    assert_select '.chat-typing[data-team-chat-target=typing]'
    assert_select "dialog[data-team-chat-target=newDm] form[action='#{team_chat_dms_path}']", 1
    assert_select 'main#main.max-w-none'
    get team_chat_dock_room_path('general')
    assert_select 'turbo-frame#chat_dock .chat-typing'
  end
end
