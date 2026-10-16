# frozen_string_literal: true

module MarketingHelper
  def marketing_record_fields(record)
    case record
    when Marketing::Campaign then %i[name storefront_url topics]
    when Marketing::Community then %i[campaign_id name url include_terms exclude_terms promotion_rules rules_url]
    when Marketing::Offer then %i[community_id code terms destination_url starts_at ends_at evidence_url]
    when Marketing::Thread then %i[community_id url title excerpt status availability triage_note snoozed_until]
    end
  end

  def marketing_choices(field)
    case field
    when :campaign_id then Marketing::Campaign.order(:name).limit(200).pluck(:name, :id)
    when :community_id then Marketing::Community.order(:name).limit(200).pluck(:name, :id)
    when :status then %w[new relevant dismissed snoozed].map { |value| [value.humanize, value] }
    when :availability then %w[open locked deleted].map { |value| [value.humanize, value] }
    end
  end

  def marketing_record_path(record)
    public_send("marketing_#{record.class.model_name.element.pluralize}_path")
  end

  def marketing_edit_path(record)
    public_send("edit_marketing_#{record.class.model_name.element}_path", record)
  end
end
