# frozen_string_literal: true

namespace :platform do
  desc 'Link owner-authorized Google emails to an existing active platform administrator (USER_ID required)'
  task link_owner_identities: :environment do
    user = User.find(ENV.fetch('USER_ID'))
    abort 'An existing active super administrator with an active home workspace is required.' unless user.active? && user.super_admin? && user.tenant&.status == 'active'
    emails = PlatformOwnerIdentities.emails
    abort 'Configure the owner-approved RUPERT_OWNER_GOOGLE_EMAILS list in the deployment first.' if emails.empty?
    GoogleLoginIdentity.transaction do
      emails.each do |email|
        abort "Resolve the existing account for #{email} before linking." if User.where(email: email).where.not(id: user.id).exists?
        identity = GoogleLoginIdentity.find_or_initialize_by(email: email)
        abort "Resolve the existing identity for #{email} before linking." if identity.persisted? && identity.user_id != user.id
        identity.update!(user: user)
      end
    end
    puts 'Owner identity links saved. Google subjects are pinned on first verified sign-in. No privileges or email domain permissions were created.'
  end
end
