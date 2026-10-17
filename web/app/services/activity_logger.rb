# frozen_string_literal: true

# Records business actions to the audit trail. Safe by construction: never
# raises, so a logging hiccup can't break the action being performed.
class ActivityLogger
  class << self
    def log(action, subject: nil, details: nil, actor: Current.user)
      ActivityLog.create!(
        tenant_id: Current.tenant_id,
        user_id: actor&.id,
        actor_name: actor&.display_name || actor&.email || 'system',
        action: action,
        subject_type: subject&.class&.name,
        subject_id: subject.try(:id)&.to_s,
        subject_label: subject_label(subject),
        details: details
      )
    rescue StandardError
      nil
    end

    private

    def subject_label(subject)
      return if subject.nil?

      if subject.respond_to?(:display_number)
        subject.display_number
      elsif subject.respond_to?(:order_number)
        subject.order_number
      elsif subject.respond_to?(:name)
        subject.name
      elsif subject.respond_to?(:email)
        subject.email
      end
    end
  end
end
