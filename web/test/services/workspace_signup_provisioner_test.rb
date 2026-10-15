# frozen_string_literal: true

require 'test_helper'

class WorkspaceSignupProvisionerTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: 'Existing business', subdomain: "existing#{SecureRandom.hex(4)}")
    @actor = User.create!(tenant: @tenant, name: 'Platform owner', email: "owner#{SecureRandom.hex(4)}@platform-owner.org",
      role: 'super_admin', password: 'password123')
    Current.tenant = @tenant
    @attributes = { workspace_name: 'Independent company', requested_subdomain: "company#{SecureRandom.hex(4)}", domain: "company#{SecureRandom.hex(4)}.org" }
    @info = { 'email' => "owner@#{@attributes[:domain]}", 'name' => 'New owner', 'sub' => SecureRandom.uuid, 'email_verified' => true }
  end

  teardown { Current.reset }

  test 'verified request creates only platform admission and encrypted history' do
    assert_difference ['WorkspaceSignup.count', 'WorkspaceSignupEvent.count'], 1 do
      assert_no_difference ['Tenant.count', 'User.count', 'OauthAllowedDomain.unscoped.count'] do
        request_signup
      end
    end
    request = WorkspaceSignup.last
    assert_equal 'pending', request.status
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, request.referral_domain
    assert_nil request.tenant_id
    event = request.events.last
    assert_equal @info['email'], event.data['after']['email']
    raw = WorkspaceSignupEvent.connection.select_value("SELECT payload_json FROM workspace_signup_events WHERE id = #{event.id}")
    refute_includes raw, @info['email']
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: 'approved') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
  end

  test 'approval creates isolated admin domain and local chart without provider configuration' do
    request = request_signup
    existing_accounts = Finance::Account.count
    approved = nil
    assert_difference 'Tenant.count', 1 do
      assert_difference 'User.count', 1 do
        approved = WorkspaceSignupProvisioner.approve(signup: request, actor: @actor, lock_version: 0)
      end
    end
    assert_equal 'approved', approved.status
    assert_equal @actor.id, approved.reviewer_id
    assert_equal 1, approved.lock_version
    assert_equal @tenant, Current.tenant
    assert_equal existing_accounts, Finance::Account.count
    new_tenant = approved.tenant
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, new_tenant.referral_domain
    owner = new_tenant.users.find_by!(email: @info['email'])
    assert owner.admin?
    assert owner.active?
    assert_equal WorkspaceSignup::REFERRAL_DOMAIN, owner.referral_domain
    assert OauthAllowedDomain.unscoped.exists?(tenant_id: new_tenant.id, domain: @attributes[:domain])
    assert_equal Finance::ChartOfAccounts::DEFAULT.length, Finance::Account.unscoped.where(tenant_id: new_tenant.id).count
    assert_equal 0, Setting.unscoped.where(tenant_id: new_tenant.id).count
    assert_equal 0, ApiAccessToken.unscoped.where(tenant_id: new_tenant.id).count
    assert_equal %w[requested approved], approved.events.order(:id).pluck(:action)
  end

  test 'request replay does not change pending fields or create additional history' do
    request = request_signup
    assert_no_difference ['WorkspaceSignup.count', 'WorkspaceSignupEvent.count'] do
      duplicate = WorkspaceSignupProvisioner.request_signup(info: @info, attributes: @attributes.merge(workspace_name: 'Forged rename'))
      assert_equal request.id, duplicate.id
      assert_equal 'Independent company', duplicate.workspace_name
    end
  end

  test 'rejected requests cannot reopen themselves' do
    request = request_signup
    rejected = WorkspaceSignupProvisioner.reject(signup: request, actor: @actor, lock_version: 0)
    assert_equal 'rejected', rejected.status
    assert_no_difference ['Tenant.count', 'User.count', 'WorkspaceSignupEvent.count'] do
      assert_equal 'rejected', request_signup.status
    end
    assert_raises(ActiveRecord::StaleObjectError) { WorkspaceSignupProvisioner.approve(signup: rejected, actor: @actor, lock_version: 1) }
  end

  test 'approval requires fresh active platform owner and active own workspace' do
    request = request_signup
    @actor.update!(role: 'admin')
    assert_raises(ActiveRecord::RecordNotFound) { approve(request) }
    @actor.update!(role: 'super_admin', active: false)
    assert_raises(ActiveRecord::RecordNotFound) { approve(request) }
    @actor.update!(active: true)
    @tenant.update!(status: 'suspended')
    assert_raises(ActiveRecord::RecordNotFound) { approve(request) }
    assert_equal 'pending', request.reload.status
  end

  test 'missing malformed stale and replayed versions cannot create another workspace' do
    request = request_signup
    [nil, '', '-1', '0junk', '2147483647', 1].each do |version|
      assert_raises(ActiveRecord::StaleObjectError) { WorkspaceSignupProvisioner.approve(signup: request, actor: @actor, lock_version: version) }
    end
    approve(request)
    assert_no_difference ['Tenant.count', 'User.count', 'WorkspaceSignupEvent.count'] do
      assert_raises(ActiveRecord::StaleObjectError) { approve(request) }
    end
  end

  test 'mandatory audit failure rolls back all admission writes' do
    request = request_signup
    WorkspaceSignupEvent.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(WorkspaceSignupEvent.new))
    assert_no_difference ['Tenant.count', 'User.count', 'OauthAllowedDomain.unscoped.count', 'Finance::Account.unscoped.count'] do
      assert_raises(ActiveRecord::RecordInvalid) { approve(request) }
    end
    assert_equal 'pending', request.reload.status
    assert_equal 0, request.lock_version
    assert_nil request.tenant_id
  end

  test 'approval rechecks domain workspace and email availability' do
    request = request_signup
    OauthAllowedDomain.create!(tenant_id: @tenant.id, domain: @attributes[:domain])
    assert_no_difference 'Tenant.count' do
      assert_raises(ActiveRecord::RecordInvalid) { approve(request) }
    end
    assert_equal 'pending', request.reload.status
  end

  test 'two applicants for one domain cannot both receive a workspace' do
    first = request_signup
    second = WorkspaceSignupProvisioner.request_signup(info: @info.merge('email' => "colleague@#{@attributes[:domain]}", 'sub' => SecureRandom.uuid),
      attributes: @attributes.merge(requested_subdomain: "alternate#{SecureRandom.hex(4)}"))
    approve(first)
    assert_no_difference ['Tenant.count', 'User.count', 'WorkspaceSignupEvent.count'] do
      assert_raises(ActiveRecord::RecordInvalid) { approve(second) }
    end
    assert_equal 'pending', second.reload.status
  end

  test 'approved domain has a database unique invariant across separate requests' do
    first = request_signup
    second = WorkspaceSignupProvisioner.request_signup(info: @info.merge('email' => "colleague@#{@attributes[:domain]}", 'sub' => SecureRandom.uuid),
      attributes: @attributes.merge(requested_subdomain: "alternate#{SecureRandom.hex(4)}"))
    approve(first)
    assert_raises(ActiveRecord::RecordNotUnique) do
      WorkspaceSignup.transaction(requires_new: true) { WorkspaceSignup.where(id: second.id).update_all(status: 'approved') }
    end
  end

  test 'unverified identity mismatched domain and consumer email are rejected' do
    [false, nil, 'false', 1].each do |verified|
      assert_raises(GoogleOauthService::ExchangeError) do
        WorkspaceSignupProvisioner.request_signup(info: @info.merge('email_verified' => verified), attributes: @attributes)
      end
    end
    assert_raises(GoogleOauthService::ExchangeError) do
      WorkspaceSignupProvisioner.request_signup(info: @info.merge('sub' => ''), attributes: @attributes)
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      WorkspaceSignupProvisioner.request_signup(info: @info.merge('email' => 'owner@another-company.org'), attributes: @attributes)
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      WorkspaceSignupProvisioner.request_signup(info: @info.merge('email' => 'owner@gmail.com'), attributes: @attributes.merge(domain: 'gmail.com'))
    end
  end

  test 'existing account and changed Google subject cannot request another workspace' do
    User.create!(tenant: @tenant, email: @info['email'], name: 'Already here', password: 'password123')
    assert_raises(ActiveRecord::RecordInvalid) { request_signup }
    User.find_by(email: @info['email']).destroy!
    request_signup
    assert_raises(GoogleOauthService::ExchangeError) do
      WorkspaceSignupProvisioner.request_signup(info: @info.merge('sub' => SecureRandom.uuid), attributes: @attributes)
    end
  end

  test 'domain and workspace inputs reject unsafe or reserved values' do
    %w[localhost internal.local 127.0.0.1 company.test https://company.org company.org/ company..org -company.org company-.org company.org.].each do |domain|
      refute WorkspaceSignup.private_domain?(domain), domain
    end
    WorkspaceSignup::RESERVED_SUBDOMAINS.each do |subdomain|
      record = WorkspaceSignup.new(@attributes.merge(email: @info['email'], applicant_name: 'Name', google_subject: SecureRandom.uuid,
        requested_subdomain: subdomain, writer_checked: true))
      refute record.valid?, subdomain
    end
  end

  private

  def request_signup
    WorkspaceSignupProvisioner.request_signup(info: @info, attributes: @attributes)
  end

  def approve(request)
    WorkspaceSignupProvisioner.approve(signup: request, actor: @actor, lock_version: 0)
  end
end

class WorkspaceSignupProvisionerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @suffix = SecureRandom.hex(6)
    @tenant = Tenant.create!(name: 'Signup race owner', subdomain: "signup-race-#{@suffix}")
    @actor = User.create!(tenant: @tenant, name: 'Owner', email: "race-#{@suffix}@platform-owner.org", role: 'super_admin', password: 'password123')
    @domain = "race-#{@suffix}.org"
    @first = WorkspaceSignupProvisioner.request_signup(
      info: { 'email' => "owner@#{@domain}", 'name' => 'New owner', 'sub' => SecureRandom.uuid, 'email_verified' => true },
      attributes: { workspace_name: 'Race company', requested_subdomain: "race-one-#{@suffix}", domain: @domain })
  end

  teardown do
    requests = WorkspaceSignup.where(domain: @domain)
    tenant_ids = requests.pluck(:tenant_id).compact + [@tenant.id]
    WorkspaceSignupEvent.where(workspace_signup_id: requests.select(:id)).delete_all
    requests.delete_all
    OauthAllowedDomain.unscoped.where(tenant_id: tenant_ids).delete_all
    Finance::Account.unscoped.where(tenant_id: tenant_ids).delete_all
    User.where(tenant_id: tenant_ids).delete_all
    Tenant.where(id: tenant_ids).delete_all
    Current.reset
  end

  test 'two database sessions approving one version produce one workspace and one approval event' do
    results = race([@first, @first])
    assert_equal 1, results.count { |result| result.is_a?(WorkspaceSignup) }, results.map(&:class).inspect
    assert_equal 1, results.count { |result| result.is_a?(ActiveRecord::StaleObjectError) }, results.map(&:class).inspect
    assert_equal 1, @first.reload.lock_version
    assert_equal 1, @first.events.where(action: 'approved').count
    assert_equal 1, Tenant.where(subdomain: "race-one-#{@suffix}").count
    assert_equal 1, User.where(email: "owner@#{@domain}").count
  end

  test 'two database sessions approving separate requests for one domain cannot create two owners' do
    second = WorkspaceSignupProvisioner.request_signup(
      info: { 'email' => "other@#{@domain}", 'name' => 'Other owner', 'sub' => SecureRandom.uuid, 'email_verified' => true },
      attributes: { workspace_name: 'Other company', requested_subdomain: "race-two-#{@suffix}", domain: @domain })
    results = race([@first, second])
    assert_equal 1, results.count { |result| result.is_a?(WorkspaceSignup) }, results.map(&:class).inspect
    assert_equal 1, results.count { |result| result.is_a?(ActiveRecord::RecordInvalid) }, results.map(&:class).inspect
    assert_equal 1, WorkspaceSignup.where(domain: @domain, status: 'approved').count
    assert_equal 1, WorkspaceSignup.where(domain: @domain, status: 'pending').count
    assert_equal 1, OauthAllowedDomain.unscoped.where(domain: @domain).count
    assert_equal 1, User.where(email: ["owner@#{@domain}", "other@#{@domain}"]).count
  end

  private

  def race(requests)
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = requests.map do |request|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          selected = WorkspaceSignup.find(request.id)
          ready << true
          start.pop
          outcomes << WorkspaceSignupProvisioner.approve(signup: selected, actor: @actor, lock_version: 0)
        ensure
          Current.reset
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    requests.length.times { ready.pop }
    requests.length.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent signup approval timed out' }
    requests.length.times.map { outcomes.pop }
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
