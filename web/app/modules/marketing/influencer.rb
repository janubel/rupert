# frozen_string_literal: true

module Marketing
  class Influencer < Record
    self.table_name = 'marketing_influencers'
    STAGES = %w[prospect shortlisted contacted interested active completed declined do_not_contact].freeze
    PRIVATE_FIELDS = %i[contact_email shipping_details private_notes].freeze
    encrypts(*PRIVATE_FIELDS)
    belongs_to :owner, class_name: 'User', optional: true
    has_many :engagements, class_name: 'Marketing::Engagement'
    has_many :interactions, class_name: 'Marketing::Interaction'
    before_validation { self.profile_url = profile_url.present? ? Urls.canonical(profile_url) : nil }
    validates :name, presence: true, length: { maximum: 200 }
    validates :platform, :handle, length: { maximum: 200 }
    validates :topics, :notes, :shipping_details, :private_notes, length: { maximum: 5000 }
    validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }, allow_blank: true
    validates :profile_url, uniqueness: { scope: :tenant_id }, allow_nil: true
    validates :stage, inclusion: { in: STAGES }
    validate { https_fields(:profile_url) if profile_url.present? }
    validate do
      errors.add(:owner, 'must be active in this workspace') if owner && (owner.tenant_id != tenant_id || !owner.active?)
    end

    def contactable?
      !%w[declined do_not_contact].include?(stage)
    end
  end
end
