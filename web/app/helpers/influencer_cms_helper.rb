# frozen_string_literal: true

module InfluencerCmsHelper
  def influencer_cms_fields(record)
    private_access = Current.user.can?('marketing.contacts')
    case record
    when Marketing::Influencer
      Marketing::CmsWriter::INFLUENCER_FIELDS + (private_access ? Marketing::Influencer::PRIVATE_FIELDS : [])
    when Marketing::Engagement
      Marketing::CmsWriter::ENGAGEMENT_FIELDS
    when Marketing::Offer
      Marketing::InfluencerOfferWriter::FIELDS
    when Marketing::ProductGift
      Marketing::GiftWorkflow::PUBLIC_FIELDS + (private_access ? Marketing::GiftWorkflow::DELIVERY_FIELDS : [])
    when Marketing::Document
      %i[title kind visibility body source_url]
    end
  end

  def influencer_cms_choices(record, field)
    case field
    when :stage then Marketing::Influencer::STAGES.map { |s| [s.humanize, s] }
    when :status then Marketing::Engagement::STATUSES.map { |s| [s.humanize, s] }
    when :campaign_id then Marketing::Campaign.order(:name).limit(200).pluck(:name, :id)
    when :owner_id then User.active.where(tenant_id: Current.tenant_id).order(:email).limit(200).map { |u| [u.display_name, u.id] }
    when :visibility then Current.user.can?('marketing.contacts') ? [['Marketing readers', 'internal'], ['Restricted contacts access', 'restricted']] : [['Marketing readers', 'internal']]
    when :kind then Marketing::Document::KINDS.map { |s| [s.humanize, s] } if record.is_a?(Marketing::Document)
    end
  end

  def influencer_cms_events(record)
    Marketing::CmsEvent.where(subject_type: record.class.name, subject_id: record.id).order(id: :desc).limit(20)
  end
end
