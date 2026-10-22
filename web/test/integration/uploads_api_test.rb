# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

class UploadsApiTest < ActionDispatch::IntegrationTest
  include UploadFixtures
  include AskRupertHelper

  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def issue(scopes)
    Current.tenant = @tenant
    token, secret = ApiAccessToken.issue(attributes: { name: 'Tailnet curl', scopes: scopes }, user: @owner.reload, tenant: @tenant)
    assert token.persisted?, token.errors.full_messages.to_sentence
    secret
  end

  def bearer(secret) = { 'Authorization' => "Bearer #{secret}" }

  def send_file(secret, content, name, field: 'file')
    post api_v1_uploads_path, params: { field => upload_file(content, name) }, headers: bearer(secret)
  end

  test 'a token with uploads:write can send a file and gets the id, hash and status back' do
    secret = issue(['uploads:write'])
    send_file(secret, BANK_CSV, 'statement.csv')
    assert_response :created
    data = response.parsed_body.fetch('data').first
    assert_equal 'recognized', data['status']
    assert_equal Digest::SHA256.hexdigest(BANK_CSV), data['sha256']
    assert_equal 'bank_statement', data['importer']
    assert_equal "/uploads/#{data['id']}", data['review_url']
    upload = Upload.find(data['id'])
    assert_equal 'api', upload.origin
    assert_equal 'Tailnet curl', upload.via_token_label
    assert_equal @owner.id, upload.uploaded_by_id
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_no_match(/UPS STORE/, response.body)
  end

  test 'a repeat is a 200 duplicate, a refused file is a 422 with the reason' do
    secret = issue(['uploads:write'])
    send_file(secret, BANK_CSV, 'a.csv')
    send_file(secret, BANK_CSV, 'again.csv')
    assert_response :ok
    assert_equal 'duplicate', response.parsed_body.dig('data', 0, 'status')
    send_file(secret, 'MZ', 'run.exe')
    assert_response :unprocessable_entity
    assert_match(/Unsupported file type/, response.parsed_body.dig('data', 0, 'status_text'))
  end

  test 'scopes, tokens and bodies are checked' do
    post api_v1_uploads_path, params: { file: upload_file(BANK_CSV, 'a.csv') }
    assert_response :unauthorized
    send_file(issue(['inventory:read']), BANK_CSV, 'a.csv')
    assert_response :forbidden
    secret = issue(['uploads:write'])
    post api_v1_uploads_path, headers: bearer(secret)
    assert_response :bad_request
    assert_equal 'no_file', response.parsed_body.dig('error', 'code')
    post api_v1_uploads_path, params: { file: 'just text, not a file' }, headers: bearer(secret)
    assert_response :bad_request
    get api_v1_uploads_path, headers: bearer(secret)
    assert_response :forbidden, 'uploads:write alone cannot read the list'
    assert_equal 0, Upload.count
  end

  test 'an uploads:write token can send files but never approve an import' do
    secret = issue(['uploads:write'])
    send_file(secret, BANK_CSV, 'a.csv')
    upload = Upload.last
    post "/uploads/#{upload.id}/approve", headers: bearer(secret)
    assert_redirected_to login_path
    assert_equal 0, BankStatementLine.count
    assert_includes ApiAccessToken::WRITE_SCOPES, 'uploads:write'
    assert_not_includes AskRupert::ScopedToken::READ_SCOPES, 'uploads:write'
  end

  test 'listing needs uploads:read and is limited to the token workspace' do
    secret = issue(%w[uploads:write uploads:read])
    send_file(secret, BANK_CSV, 'a.csv')
    other = Tenant.create!(name: 'Other upload api', subdomain: 'other-upload-api')
    Current.tenant = other
    Upload.create!(tenant_id: other.id, filename: 'private.csv', file_format: 'csv', byte_size: 1, status: 'rejected', reason: 'x')
    Current.tenant = @tenant
    get api_v1_uploads_path, headers: bearer(secret)
    assert_response :success
    assert_equal ['a.csv'], response.parsed_body['data'].map { |row| row['filename'] }
    get api_v1_upload_path(Upload.last), headers: bearer(secret)
    assert_response :success
    get api_v1_upload_path(Upload.unscoped.find_by(filename: 'private.csv')), headers: bearer(secret)
    assert_response :not_found
  end

  test 'sending is throttled per token' do
    secret = issue(['uploads:write'])
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    # Rack::Attack counts in fixed one-minute windows; freeze the clock inside one
    # so a slow run can't straddle a boundary and reset the count.
    travel_to(Time.zone.at(((Time.current.to_i / 60) * 60) + 1)) do
      31.times { |i| send_file(secret, "a,b\n#{i},#{i}\n", "f#{i}.csv") }
    end
    assert_response :too_many_requests
  ensure
    Rack::Attack.enabled = false
  end

  test 'the MCP tool answers did-my-file-arrive without any contents' do
    secret = issue(%w[uploads:write uploads:read])
    send_file(secret, BANK_CSV, 'statement.csv')
    send_file(secret, UNKNOWN_CSV, 'mystery.csv')
    post mcp_path, params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'list_uploads', arguments: { query: 'mystery' } } }.to_json,
      headers: bearer(secret).merge('Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream')
    assert_response :success
    result = response.parsed_body.fetch('result')
    assert_not result['isError']
    text = result.dig('content', 0, 'text')
    assert_match(/mystery.csv: needs_review/, text)
    rows = result.fetch('structuredContent').fetch('rows')
    assert_equal ['mystery.csv'], rows.map { |row| row['filename'] }
    assert_no_match(/alpha,beta/, result.to_json)

    post mcp_path, params: { jsonrpc: '2.0', id: 2, method: 'tools/list' }.to_json,
      headers: bearer(issue(['inventory:read'])).merge('Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream')
    assert_not_includes response.parsed_body.dig('result', 'tools').map { |tool| tool['name'] }, 'list_uploads'
  end

  test 'Ask Rupert can report on uploads for someone allowed, and only that' do
    Uploads::Intake.call(StringIO.new(BANK_CSV), filename: 'oct.csv', origin: 'web', actor: @owner)
    admin = person('admin')
    Current.user = admin
    conversation = AskRupert::Conversation.create!(user: admin)
    tools = AskRupert::Tools.new(user: admin, conversation: conversation)
    result = tools.call('run_report', { 'report' => 'list_uploads', 'arguments' => { 'query' => 'oct' } })
    assert result.ok, result.text
    assert_match(/oct.csv: recognized/, result.text)
    assert_equal '/uploads', result.links.first[:path]

    shift = person('shift_leader')
    refused = AskRupert::Tools.new(user: shift, conversation: AskRupert::Conversation.create!(user: shift)).call('run_report', { 'report' => 'list_uploads' })
    assert_not refused.ok
  end
end
