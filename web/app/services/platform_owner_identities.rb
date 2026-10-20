# frozen_string_literal: true

# Owner mailbox configuration belongs to the deployment, not public source.
# These addresses identify intended links; they never grant a role by themselves.
class PlatformOwnerIdentities
  def self.emails
    ENV.fetch('RUPERT_OWNER_GOOGLE_EMAILS', '').split(',').map { |value| value.strip.downcase }
      .select { |value| value.length <= 254 && value.match?(URI::MailTo::EMAIL_REGEXP) }.uniq.first(10)
  end
end
