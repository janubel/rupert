# frozen_string_literal: true

require 'test_helper'

class OwnerChecklistsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.user = @admin
    @checklist = OwnerChecklistWriter.create(attributes: owner_attributes, actor: @admin)
    assert @checklist.persisted?, @checklist.errors.full_messages.to_sentence
    @feature = OwnerChecklist.features.find { |feature| feature['status'] == 'Available' }
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'owner creates edits and reviews private domain metadata with privacy on all screens' do
    get owner_checklists_path
    assert_response :success
    assert_owner_privacy
    assert_select 'h1', 'Owner checklists'
    get new_owner_checklist_path
    assert_response :success
    assert_owner_privacy
    assert_select 'form[data-turbo=false]'
    assert_select 'input[name="owner_checklist[owner_phone]"]'
    post owner_checklists_path, params: { owner_checklist: owner_attributes.merge(name: 'Second private domain', domain: 'second-owner.org') }
    created = OwnerChecklist.order(:id).last
    assert_redirected_to owner_checklist_path(created)
    assert_equal 'Second private domain', created.data['name']
    get edit_owner_checklist_path(@checklist)
    assert_response :success
    assert_owner_privacy
    assert_select 'input[name=lock_version]'
    patch owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version,
      owner_checklist: { purpose: 'Updated private operating purpose', owner_phone: '+1 555 010 0123' } }
    assert_redirected_to owner_checklist_path(@checklist)
    get owner_checklist_path(@checklist)
    assert_response :success
    assert_owner_privacy
    assert_includes response.body, 'Updated private operating purpose'
    assert_includes response.body, '+1 555 010 0123'
    assert_equal 2, @checklist.owner_checklist_events.count
    assert_select "a[href='#{print_owner_checklist_path(@checklist)}']", 'Print private copy'
  end

  test 'service form stores references due dates and explicit archive state without provider operations' do
    get service_owner_checklist_path(@checklist)
    assert_response :success
    assert_owner_privacy
    assert_select 'input[type=password]', count: 0
    assert_select 'form[data-turbo=false]'
    assert_select 'input[name="owner_service[login_url]"]'
    version = @checklist.lock_version
    payload = { lock_version: version, owner_service: service_attributes }
    assert_no_difference ['SyncRun.count', 'InventoryMovement.count', 'Core::Payment.count'] do
      patch save_service_owner_checklist_path(@checklist), params: payload
      assert_redirected_to owner_checklist_path(@checklist)
    end
    @checklist.reload
    assert_equal 1, @checklist.services.length
    service_id = @checklist.services.keys.first
    service = @checklist.services.fetch(service_id)
    assert_equal 'Business vault / domain account', service['vault_reference']
    assert_equal 'enabled', service['mfa_status']
    get owner_checklists_path
    assert_includes response.body, 'overdue dates'
    get owner_checklist_path(@checklist)
    assert_response :success
    assert_select "a[href='https://accounts.owner-example.org/login'][target='_blank'][rel='nofollow noopener noreferrer'][referrerpolicy='no-referrer']", 'Open saved login'
    get service_owner_checklist_path(@checklist, service_id: service_id)
    assert_response :success
    assert_owner_privacy
    patch save_service_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version,
      service_id: service_id, owner_service: { archived: '1' } }
    assert_redirected_to owner_checklist_path(@checklist)
    assert @checklist.reload.services.fetch(service_id)['archived']
    get owner_checklists_path
    refute_includes response.body, 'overdue dates'
    assert_equal 0, @checklist.services.values.count { |entry| entry['password'].present? }
  end

  test 'invalid credential-bearing and local login URLs are never reflected or saved' do
    urls = ['https://accounts.owner-example.org/login?token=NEVER_ECHO_LOGIN_TOKEN',
      'https://owner:NEVER_ECHO_LOGIN_TOKEN@accounts.owner-example.org/login', 'https://127.0.0.1/login',
      'https://localhost/login', 'https://accounts.owner-example.org:8443/login', 'https://accounts.owner-example.org/login#NEVER_ECHO_LOGIN_TOKEN']
    urls.each do |url|
      assert_no_difference 'OwnerChecklistEvent.count' do
        patch save_service_owner_checklist_path(@checklist), params: { lock_version: @checklist.reload.lock_version,
          owner_service: service_attributes.merge(login_url: url) }
      end
      assert_response :unprocessable_entity
      assert_owner_privacy
      assert_select 'input[name="owner_service[login_url]"][value=""]'
      refute_includes response.body, 'NEVER_ECHO_LOGIN_TOKEN'
      refute_includes response.body, url
      assert_empty @checklist.reload.services
    end
  end

  test 'invalid domain credentials are cleared while generic validation feedback stays private' do
    post owner_checklists_path, params: { owner_checklist: owner_attributes.merge(domain: 'https://owner:PRIVATE_DOMAIN_TOKEN@owner-example.org') }
    assert_response :unprocessable_entity
    assert_owner_privacy
    assert_select 'input[name="owner_checklist[domain]"][value=""]'
    refute_includes response.body, 'PRIVATE_DOMAIN_TOKEN'
  end

  test 'stale owner and duplicate service forms cannot overwrite or add extra records' do
    old_version = @checklist.lock_version
    patch owner_checklist_path(@checklist), params: { lock_version: old_version, owner_checklist: { notes: 'First committed change' } }
    assert_redirected_to owner_checklist_path(@checklist)
    assert_no_difference 'OwnerChecklistEvent.count' do
      patch owner_checklist_path(@checklist), params: { lock_version: old_version, owner_checklist: { notes: 'Stale discarded change' } }
    end
    assert_redirected_to owner_checklist_path(@checklist)
    assert_includes flash[:alert], 'changed in another session'
    assert_equal 'First committed change', @checklist.reload.data['notes']
    payload = { lock_version: @checklist.lock_version, owner_service: service_attributes }
    patch save_service_owner_checklist_path(@checklist), params: payload
    assert_redirected_to owner_checklist_path(@checklist)
    assert_no_difference 'OwnerChecklistEvent.count' do
      patch save_service_owner_checklist_path(@checklist), params: payload
    end
    assert_redirected_to owner_checklist_path(@checklist)
    assert_equal 1, @checklist.reload.services.length
    assert_includes flash[:alert], 'changed in another session'
  end

  test 'feature passes require actual evidence date and fresh attestation and never promote planned code' do
    get feature_owner_checklist_path(@checklist, feature_id: @feature['id'])
    assert_response :success
    assert_owner_privacy
    assert_select 'input[name="owner_feature[attest_scope]"][type=checkbox]:not([checked])'
    patch review_feature_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version, feature_id: @feature['id'], catalog_fingerprint: OwnerChecklist.catalog_fingerprint(@feature),
      owner_feature: { status: 'passed', evidence: '', tested_on: Date.current.iso8601, attest_scope: '0' } }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /Passing requires/
    assert_empty @checklist.reload.feature_reviews
    patch review_feature_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version, feature_id: @feature['id'], catalog_fingerprint: OwnerChecklist.catalog_fingerprint(@feature),
      owner_feature: { status: 'passed', evidence: 'Owner tested the current published scope with a fixture.', tested_on: Date.current.iso8601, attest_scope: '1' } }
    assert_redirected_to owner_checklist_path(@checklist, anchor: "feature-#{@feature['id']}")
    assert_equal 'passed', @checklist.reload.feature_review(@feature)['status']
    get feature_owner_checklist_path(@checklist, feature_id: @feature['id'])
    assert_select 'input[name="owner_feature[attest_scope]"][type=checkbox]:not([checked])'
    planned = OwnerChecklist.features.find { |entry| entry['status'] == 'Planned' }
    assert planned, 'catalog must contain a planned acceptance fixture'
    get feature_owner_checklist_path(@checklist, feature_id: planned['id'])
    assert_select 'option[value=passed][disabled]'
    patch review_feature_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version, feature_id: planned['id'], catalog_fingerprint: OwnerChecklist.catalog_fingerprint(planned),
      owner_feature: { status: 'passed', evidence: 'Cannot certify unimplemented work.', tested_on: Date.current.iso8601, attest_scope: '1' } }
    assert_response :unprocessable_entity
    assert_equal 'Planned', OwnerChecklist.features.find { |entry| entry['id'] == planned['id'] }['status']
    refute @checklist.reload.feature_reviews.key?(planned['id'])
  end

  test 'an open feature form cannot attest a catalog scope changed after display' do
    get feature_owner_checklist_path(@checklist, feature_id: @feature['id'])
    assert_response :success
    shown_fingerprint = css_select('input[name=catalog_fingerprint]').first['value']
    changed = @feature.merge('scope' => 'A new scope that was not shown by the open form.')
    catalog = OwnerChecklist.features.map { |entry| entry['id'] == changed['id'] ? changed : entry }
    OwnerChecklist.stubs(:features).returns(catalog)
    assert_no_difference 'OwnerChecklistEvent.count' do
      patch review_feature_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version,
        feature_id: @feature['id'], catalog_fingerprint: shown_fingerprint,
        owner_feature: { status: 'passed', evidence: 'Tested the old displayed scope.', tested_on: Date.current.iso8601, attest_scope: '1' } }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'new scope that was not shown'
    assert_select 'input[name="owner_feature[attest_scope]"][type=checkbox]:not([checked])'
    assert_select '[role=alert]', /scope changed/
    assert_empty @checklist.reload.feature_reviews
  end

  test 'new catalog entries appear unreviewed and scope changes invalidate earlier acceptance' do
    Current.user = @admin
    @checklist = OwnerChecklistWriter.review_feature(checklist: @checklist, feature_id: @feature['id'],
      attributes: { status: 'passed', evidence: 'Current scope accepted in test.', tested_on: Date.current.iso8601, attest_scope: '1' },
      lock_version: @checklist.lock_version, actor: @admin, expected_catalog_fingerprint: OwnerChecklist.catalog_fingerprint(@feature))
    changed = @feature.merge('scope' => 'Changed current scope requires a fresh owner test.')
    added = { 'id' => 'F9999', 'name' => 'New catalog acceptance fixture', 'area' => 'Test', 'status' => 'Planned', 'scope' => 'Unimplemented fixture.' }
    catalog = OwnerChecklist.features.map { |entry| entry['id'] == changed['id'] ? changed : entry } + [added]
    OwnerChecklist.stubs(:features).returns(catalog)
    get owner_checklist_path(@checklist)
    assert_response :success
    assert_includes response.body, 'New catalog acceptance fixture'
    assert_select "#feature-#{@feature['id']}", /Scope changed/
    assert_select '#owner-review-coverage', /0 of #{catalog.length}/
    assert_select '#feature-F9999', /Not reviewed/
    get feature_owner_checklist_path(@checklist, feature_id: @feature['id'])
    assert_response :success
    assert_select '[role=status]', /catalog changed/
  end

  test 'print is authenticated self-contained escaped current data with bounded immutable actor history' do
    Current.user = @admin
    @checklist = OwnerChecklistWriter.save_service(checklist: @checklist, attributes: service_attributes,
      lock_version: @checklist.lock_version, actor: @admin)
    20.times do |index|
      @checklist = OwnerChecklistWriter.update(checklist: @checklist, attributes: { notes: "Private history version #{index}" },
        lock_version: @checklist.lock_version, actor: @admin)
    end
    @checklist = OwnerChecklistWriter.review_feature(checklist: @checklist, feature_id: @feature['id'],
      attributes: { status: 'pending', evidence: '<script>PRIVATE_TEXT_ONLY</script>', tested_on: '', attest_scope: '0' },
      lock_version: @checklist.lock_version, actor: @admin)
    @admin.update!(email: 'renamed-owner@example.com')
    get print_owner_checklist_path(@checklist)
    assert_response :success
    assert_owner_privacy
    assert_select '.feature-catalog tbody tr', count: OwnerChecklist.features.length
    assert_includes response.body, 'latest 20 of 23 retained events'
    assert_includes response.body, 'admin@example.com'
    assert_includes response.body, '+1 555 010 0101'
    assert_includes response.body, 'https://accounts.owner-example.org/login'
    assert_includes response.body, '&lt;script&gt;PRIVATE_TEXT_ONLY&lt;/script&gt;'
    refute_includes response.body, '<script>PRIVATE_TEXT_ONLY</script>'
    refute_includes response.body, 'fonts.googleapis.com'
    assert_select 'link[href^="http"]', count: 0
    assert_select 'script[src]', count: 0
    assert_select 'img', count: 0
    assert_select 'nav', count: 0
    assert_select 'button[onclick="window.print()"]', 'Print private copy'
    refute_match(/<body[^>]*onload/i, response.body)
    assert_includes response.body, '@media print'
    assert_select "a[href='https://accounts.owner-example.org/login'][rel='nofollow noopener noreferrer']", 'https://accounts.owner-example.org/login'
  end

  test 'settings permission overrides cannot delegate owner access while owner role does not depend on them' do
    manager = User.create!(tenant: @tenant, email: 'delegated-settings@example.com', password: 'password123', role: 'manager')
    manager.update_permission_overrides!(%w[settings.read settings.write users.read users.write])
    delete logout_path
    post login_path, params: { email: manager.email, password: 'password123' }
    [owner_checklists_path, new_owner_checklist_path, owner_checklist_path(@checklist), edit_owner_checklist_path(@checklist),
      print_owner_checklist_path(@checklist), service_owner_checklist_path(@checklist),
      feature_owner_checklist_path(@checklist, feature_id: @feature['id'])].each do |path|
      get path
      assert_response :forbidden
      assert_equal 'no-store', response.headers['Cache-Control']
      refute_includes response.body, 'Private operating domain'
    end
    assert_no_difference ['OwnerChecklist.count', 'OwnerChecklistEvent.count'] do
      post owner_checklists_path, params: { owner_checklist: owner_attributes }
      assert_response :forbidden
      patch owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version, owner_checklist: { notes: 'Forbidden' } }
      assert_response :forbidden
      patch save_service_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version, owner_service: service_attributes }
      assert_response :forbidden
      patch review_feature_owner_checklist_path(@checklist), params: { lock_version: @checklist.lock_version, feature_id: @feature['id'], owner_feature: { status: 'pending' } }
      assert_response :forbidden
    end
    @admin.update_permission_overrides!(['inventory.read'])
    delete logout_path
    post login_path, params: { email: @admin.email, password: 'password' }
    get owner_checklist_path(@checklist)
    assert_response :success
  end

  test 'active super admins can use the owner workspace and anonymous print requests stay private' do
    delete logout_path
    get print_owner_checklist_path(@checklist)
    assert_redirected_to login_path
    assert_equal 'no-store', response.headers['Cache-Control']
    super_admin = User.create!(tenant: @tenant, email: 'owner-super-admin@example.com', password: 'password123', role: 'super_admin')
    post login_path, params: { email: super_admin.email, password: 'password123' }
    get print_owner_checklist_path(@checklist)
    assert_response :success
    assert_owner_privacy
  end

  test 'inactive workspace and inactive accounts cannot open private records' do
    @tenant.update!(status: 'suspended')
    get print_owner_checklist_path(@checklist)
    assert_response :forbidden
    assert_equal 'no-store', response.headers['Cache-Control']
    refute_includes response.body, 'Private operating domain'
    @tenant.update!(status: 'active')
    @admin.update!(active: false)
    get print_owner_checklist_path(@checklist)
    assert_redirected_to login_path
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'foreign checklist and foreign service identifiers cannot cross tenant boundaries' do
    other = Tenant.create!(name: 'Other private store', subdomain: 'other-private-owner')
    actor = User.create!(tenant: other, email: 'other-private-owner@example.com', password: 'password123', role: 'admin')
    Current.user = actor
    foreign = OwnerChecklistWriter.create(attributes: owner_attributes.merge(name: 'FOREIGN OWNER CHECKLIST', domain: 'foreign-owner.org'), actor: actor)
    foreign = OwnerChecklistWriter.save_service(checklist: foreign, attributes: service_attributes.merge(name: 'FOREIGN SERVICE'), lock_version: foreign.lock_version, actor: actor)
    service_id = foreign.services.keys.first
    Current.user = @admin
    get owner_checklists_path
    assert_response :success
    refute_includes response.body, 'FOREIGN OWNER CHECKLIST'
    [owner_checklist_path(foreign), edit_owner_checklist_path(foreign), print_owner_checklist_path(foreign),
      service_owner_checklist_path(foreign), feature_owner_checklist_path(foreign, feature_id: @feature['id'])].each do |path|
      get path
      assert_response :not_found
      assert_equal 'no-store', response.headers['Cache-Control']
      refute_includes response.body, 'FOREIGN OWNER CHECKLIST'
    end
    get service_owner_checklist_path(@checklist, service_id: service_id)
    assert_response :not_found
    assert_no_difference 'OwnerChecklistEvent.count' do
      patch save_service_owner_checklist_path(@checklist), params: { service_id: service_id, lock_version: @checklist.lock_version, owner_service: { name: 'Hijacked' } }
      assert_response :not_found
      patch owner_checklist_path(foreign), params: { lock_version: foreign.lock_version, owner_checklist: { name: 'Hijacked' } }
      assert_response :not_found
    end
  end

  private

  def owner_attributes
    { name: 'Private operating domain', domain: 'owner-example.org', purpose: 'Private store operations and owner acceptance',
      owner_name: 'Private Owner', owner_email: 'owner@example.com', owner_phone: '+1 555 010 0101', notes: 'Private operating references only.' }
  end

  def service_attributes
    { name: 'Domain account', purpose: 'Operate the business domain', login_url: 'https://accounts.owner-example.org/login',
      renewal_cadence: 'yearly', renewal_on: (Date.current - 1).iso8601, renewal_notes: 'Review the real vendor renewal notice.',
      review_cadence: 'quarterly', next_review_on: Date.current.iso8601, support_name: 'Vendor support', support_email: 'support@example.com',
      support_phone: '+1 555 010 0199', mfa_status: 'enabled', vault_reference: 'Business vault / domain account', notes: 'Reference only.', archived: '0' }
  end

  def assert_owner_privacy
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
    assert_equal 'DENY', response.headers['X-Frame-Options']
    assert_includes response.headers['X-Robots-Tag'], 'noarchive'
    assert_match(/frame-ancestors 'none'/, response.headers['Content-Security-Policy'])
    assert_select 'meta[name=turbo-cache-control][content=no-cache]'
    assert_select 'meta[name=referrer][content=no-referrer]'
  end
end
