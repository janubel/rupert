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
end
