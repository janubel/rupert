# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatAuthorizedLinksTest < ActiveSupport::TestCase
  include TeamChatHelper

  class ObservedAgent < TeamChat::Agent
    attr_reader :snapshots

    def initialize(...)
      super
      @snapshots = []
    end

    def publish(text)
      @last_publish = 0
      super
      @snapshots << @reply.reload.body
    end
  end

  setup do
    Current.tenant = @tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def filtered(text, user: @user) = TeamChat::Links.for_user(text, user: user)

  def limited!
    @user.update_permission_overrides!(%w[settings.write dashboard.read])
  end

  def pending
    TeamChat::Post.call(room: @room, user: @user, body: '@rupert help me find the right payroll page and explain it').reply
  end

  test 'denied real routes lose their active links while permitted guide pages and labels survive' do
    limited!
    assert TeamChat::Links.real?('/people/pay_runs')
    assert_equal 'Open Payroll or [Home](/).', filtered('Open [Payroll](/people/pay_runs) or [Home](/).')
    assert_equal 'Invented', filtered('[Invented](/invented/destination)')
  end

  test 'complete denied links never enter any streamed snapshot or the final reply' do
    limited!
    script_model(text: 'Open [Payroll](/people/pay_runs) or [Home](/).')
    reply = pending
    agent = ObservedAgent.new(reply, config: team_chat_config)
    agent.run
    assert_operator agent.snapshots.size, :>, 2
    agent.snapshots.each { |body| assert_not_includes body.to_s, '](/people/pay_runs)' }
    assert_equal 'Open Payroll or [Home](/).', reply.reload.body
    assert_equal 'succeeded', reply.run.reload.state
  end

  test 'permission memoization on an old user cannot keep a revoked link active' do
    assert_includes filtered('[Payroll](/people/pay_runs)'), '](/people/pay_runs)'
    limited!
    assert_equal 'Payroll', filtered('[Payroll](/people/pay_runs)')
  end

  test 'records use their policy rather than broad module permission or a guessed ID' do
    task = Projects::Task.create!(title: 'Authorized link task', assignee: @user)
    path = "/projects/tasks/#{task.id}"
    assert_equal "[Task](#{path})", filtered("[Task](#{path})")
    other = Tenant.create!(name: 'Other link tenant', subdomain: 'otherlinks', status: 'active')
    foreign = Projects::Task.unscoped.create!(tenant_id: other.id, title: 'Other tenant task')
    assert_equal 'Foreign', filtered("[Foreign](/projects/tasks/#{foreign.id})")
    assert_equal 'Missing', filtered('[Missing](/projects/tasks/999999999)')
    limited!
    assert_equal 'Task', filtered("[Task](#{path})")
  end

  test 'task assignment revocation is checked even when user permissions are unchanged' do
    worker = User.create!(tenant: @tenant, email: 'link-worker@example.com', name: 'Link worker', role: 'employee', password: 'password123')
    worker.update_permission_overrides!(%w[tasks.self])
    task = Projects::Task.create!(title: 'Only assigned work', assignee: worker)
    path = "/projects/tasks/#{task.id}"
    assert_equal "[Task](#{path})", filtered("[Task](#{path})", user: worker)
    signature = worker.permissions_signature
    task.update!(assignee: @user)
    assert_equal signature, worker.reload.permissions_signature
    assert_equal 'Task', filtered("[Task](#{path})", user: worker)
  end

  test 'learning links follow the current lesson catalog' do
    lesson = LearningCatalog.available(@user).first
    assert lesson
    path = "/learning/#{lesson[:key]}"
    assert_equal "[Lesson](#{path})", filtered("[Lesson](#{path})")
    assert_equal 'Missing', filtered('[Missing](/learning/not-a-lesson)')
  end

  test 'private rooms and files require access to the actual room' do
    other = User.create!(tenant: @tenant, email: 'link-private@example.com', name: 'Private', role: 'admin', password: 'password123')
    secret = TeamChat::Room.direct_for(other)
    own = "/chat/#{@room.slug}"
    assert_equal "[Own](#{own})", filtered("[Own](#{own})")
    assert_equal 'Other', filtered("[Other](/chat/#{secret.slug})")
    trigger = @room.messages.create!(user: @user, author_kind: 'person', body: 'file')
    file = trigger.attachments.create!(room: @room, filename: 'proof.txt', content_type: 'text/plain', byte_size: 5, data: 'proof')
    file_path = "/chat/#{@room.slug}/files/#{file.id}"
    assert_equal "[File](#{file_path})", filtered("[File](#{file_path})")
    assert_equal 'Other', filtered("[Other](/chat/#{secret.slug}/files/#{file.id})")
  end

  test 'encoding and route normalization cannot evade destination authorization' do
    limited!
    ['/people/%70ay_runs', '//outside.example/path', '/%2foutside.example/path', '/%2570eople/pay_runs',
     '/people/../people/pay_runs', '/people/%2e%2e/people/pay_runs', '/%5coutside.example', '/people/pay_runs%00'].each do |path|
      assert_equal 'Blocked', filtered("[Blocked](#{path})"), path
    end
    assert_equal '[Home](/#main)', filtered('[Home](/#main)')
  end

  test 'trusted absolute addresses are converted to authorized relative links and outside addresses stay inactive' do
    old_host, old_instance = ENV.values_at('HOST', 'RUPERT_INSTANCE_HOSTNAME')
    ENV['HOST'] = 'https://chat.example.test'
    ENV['RUPERT_INSTANCE_HOSTNAME'] = 'chat.example.test'
    limited!
    assert_equal 'chat.example.test/people/pay_runs', filtered('https://chat.example.test/people/pay_runs')
    assert_equal '[chat.example.test/](/).', filtered('https://chat.example.test/.')
    assert_equal 'outside.example/path', filtered('https://outside.example/path')
    assert_no_match(/https?:\/\//, filtered('https://outside.example/?next=https://chat.example.test/people/pay_runs'))
    assert_equal 'chat.example.test@outside.example/path', filtered('https://chat.example.test@outside.example/path')
  ensure
    ENV['HOST'], ENV['RUPERT_INSTANCE_HOSTNAME'] = old_host, old_instance
  end

  test 'code stays literal and malformed formatting cannot make a forbidden absolute address active' do
    limited!
    code = '`[Payroll](/people/pay_runs)`'
    assert_equal code, filtered(code)
    assert_equal '`https://outside.example/path`', filtered('`https://outside.example/path`')
    assert_no_match(/https?:\/\//, filtered('`unfinished https://outside.example/path'))
    assert_equal 'Outside', filtered('[Outside](https://outside.example/path)')
  end

  test 'retained approval links must match the task in their executed receipt' do
    reply = pending
    card = TeamChat::Actions.propose!(reply, tool: 'create_task', arguments: { 'title' => 'Link approval task' }, proposed_for: @user)
    TeamChat::Actions.decide!(reply, card['id'], user: @user, approve: true)
    approval = TeamChat::Approval.find_by!(public_id: card['id'])
    task_id = approval.events.find_by!(kind: 'executed').details.dig('result', 'id')
    path = "/projects/tasks/#{task_id}/approved_request?approval_id=#{approval.public_id}"
    assert_equal "[Request](#{path})", filtered("[Request](#{path})")
    other = Projects::Task.create!(title: 'Unrelated task')
    assert_equal 'Request', filtered("[Request](/projects/tasks/#{other.id}/approved_request?approval_id=#{approval.public_id})")
    assert_equal 'Missing', filtered("[Missing](/projects/tasks/#{task_id}/approved_request?approval_id=missing)")
    limited!
    assert_equal 'Request', filtered("[Request](#{path})")
  end

  test 'recovery scrubs an old unsafe draft before model inference resumes' do
    limited!
    reply = pending
    reply.update!(body: 'Open [Payroll](/people/pay_runs).')
    observed = []
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do
      observed << reply.reload.body
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Open [Home](/).') }
    end
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal ['Open Payroll.'], observed
    assert_equal 'Open [Home](/).', reply.reload.body
  end
end
