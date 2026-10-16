# frozen_string_literal: true

# Explicit operator-approved Google login aliases. The canonical account keeps
# its email, tenant and permissions; an alias never auto-provisions an account.
class GoogleLoginIdentity < ApplicationRecord
  belongs_to :user

  before_validation do
    self.email = email.to_s.strip.downcase
    self.google_subject = google_subject.presence
  end

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :google_subject, uniqueness: true, allow_nil: true
  validate :email_does_not_belong_to_another_account

  # A same-email link is explicit approval for this existing account, rather
  # than permission to provision every account on its public email domain.
  def exact_account_email?
    email == user.email.to_s.downcase
  end

  # Pin the first verified Google identity atomically. Future mailbox changes
  # must not silently give a different Google identity the linked permissions.
  def verify_subject!(subject)
    raise GoogleOauthService::ExchangeError, 'Google did not return an account identity.' if subject.blank?

    with_lock do
      if google_subject.present? && google_subject != subject
        raise GoogleOauthService::ExchangeError, 'This Google identity does not match the linked account. Contact an admin.'
      end

      update!(google_subject: subject) if google_subject.blank?
    end
  end

  private

  def email_does_not_belong_to_another_account
    return unless User.where(email: email).where.not(id: user_id).exists?

    errors.add(:email, 'already belongs to another account')
  end
end
