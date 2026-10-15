# frozen_string_literal: true

# Admission only: no upstream APIs, imported credentials, outbound messages or
# automatic merchant connections. Referral attribution grants no permissions.
class WorkspaceSignupProvisioner
  class << self
    def request_signup(info:, attributes:)
      unless [true, 'true'].include?(info['email_verified']) && info['sub'].is_a?(String) && info['sub'].present?
        raise GoogleOauthService::ExchangeError, 'A verified Google company email is required.'
      end
      email = info['email'].to_s.strip.downcase
      existing = WorkspaceSignup.find_by(email: email)
      if existing
        raise GoogleOauthService::ExchangeError, 'This identity does not match the existing request.' unless existing.google_subject == info['sub']

        return existing
      end
      signup = WorkspaceSignup.new(WorkspaceSignup.intent(attributes).merge(email: email,
        google_subject: info['sub'], applicant_name: info['name'].presence || email.split('@').first,
        referral_domain: WorkspaceSignup::REFERRAL_DOMAIN, writer_checked: true))
      signup.valid?
      signup.validate_availability
      raise ActiveRecord::RecordInvalid, signup if signup.errors.any?

      WorkspaceSignup.transaction do
        signup.save!
        history!(signup, nil, 'requested', {}, snapshot(signup))
      end
      signup.writer_checked = false
      signup
    rescue ActiveRecord::RecordNotUnique
      existing = WorkspaceSignup.find_by(email: email, google_subject: info['sub'])
      return existing if existing

      raise GoogleOauthService::ExchangeError, 'This Google identity already has a signup request.'
    end

    def approve(signup:, actor:, lock_version:)
      review(signup: signup, actor: actor, lock_version: lock_version, status: 'approved') do |record|
        record.validate_availability
        raise ActiveRecord::RecordInvalid, record if record.errors.any?

        tenant = Tenant.create!(name: record.workspace_name, subdomain: record.requested_subdomain,
          referral_domain: record.referral_domain, status: 'active')
        User.create!(referral_domain: record.referral_domain, tenant: tenant, email: record.email, name: record.applicant_name, role: 'admin', active: true,
          password: SecureRandom.hex(32))
        OauthAllowedDomain.create!(tenant_id: tenant.id, domain: record.domain)
        Current.set(tenant: tenant) { Finance::ChartOfAccounts.seed! }
        WorkspaceSignup.where(id: record.id).update_all(tenant_id: tenant.id, lock_version: record.lock_version + 1)
      end
    end

    def reject(signup:, actor:, lock_version:)
      review(signup: signup, actor: actor, lock_version: lock_version, status: 'rejected') { |_record| nil }
    end

    private

    def platform_actor!(actor)
      fresh = actor.is_a?(User) && actor.persisted? && User.find_by(id: actor.id, active: true, role: 'super_admin')
      raise ActiveRecord::RecordNotFound unless fresh && Tenant.exists?(id: fresh.tenant_id, status: 'active')

      fresh
    end

    def review(signup:, actor:, lock_version:, status:)
      actor = platform_actor!(actor)
      version = lock_version.to_s
      unless signup.is_a?(WorkspaceSignup) && signup.persisted? && version.match?(/\A(?:0|[1-9][0-9]{0,9})\z/) && version.to_i < 2_147_483_647
        raise ActiveRecord::StaleObjectError.new(signup, 'review')
      end
      record = WorkspaceSignup.find(signup.id)
      before = snapshot(record)
      WorkspaceSignup.transaction do
        # Conditional write comes first, so SQLite never upgrades a read lock.
        updated = WorkspaceSignup.where(id: record.id, status: 'pending', lock_version: version.to_i).update_all(
          status: status, reviewer_id: actor.id, reviewed_at: Time.current, updated_at: Time.current, lock_version: version.to_i + 1)
        raise ActiveRecord::StaleObjectError.new(record, 'review') unless updated == 1

        platform_actor!(actor)
        record.writer_checked = true
        raise ActiveRecord::RecordInvalid, record unless record.valid?

        yield record
        record.reload
        history!(record, actor, status, before, snapshot(record))
      end
      record.writer_checked = false
      record
    rescue ActiveRecord::RecordNotUnique
      record.errors.add(:base, 'This domain, workspace name or account was assigned by another request. Reload and review it.')
      raise ActiveRecord::RecordInvalid, record
    end

    def snapshot(record)
      record.attributes.slice('email', 'domain', 'workspace_name', 'requested_subdomain', 'referral_domain',
        'status', 'reviewer_id', 'reviewed_at', 'tenant_id', 'lock_version')
    end

    def history!(signup, actor, action, before, after)
      WorkspaceSignupEvent.create!(workspace_signup: signup, actor: actor, action: action, writer_checked: true,
        payload_json: JSON.generate('before' => before, 'after' => after, 'actor_email' => actor&.email))
    end
  end
end
