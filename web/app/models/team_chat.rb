# frozen_string_literal: true

# Team chat: Slack-style rooms inside Rupert with the @rupert assistant as a
# member (docs/ops/team-chat.md).
module TeamChat
  def self.table_name_prefix = 'chat_'

  # Who may use team chat. Administrators only for now.
  def self.allowed?(user)
    user.present? && user.active? && !user.employee? && user.can?('settings.write') && user.tenant_id == Current.tenant_id
  end
end
