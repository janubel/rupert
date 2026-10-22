# frozen_string_literal: true

# Admin-only mirror of the Buzz workspace. It reuses the Team chat UI and
# actions (channel list, reading, polling, scrollback and posting) from
# BuzzChatController, but the page and its JSON endpoint are gated behind
# settings.write so the mirror can sit in the administrator GUI without
# widening who can read Buzz.
class Admin::BuzzMirrorController < BuzzChatController
  # GET /admin/buzz
  def show
    super
    @chat_title = 'Buzz mirror'
    @chat_tab = :mirror
    @chat_messages_path = admin_buzz_mirror_messages_path
    @chat_base_path = admin_buzz_mirror_path
  end

  private

  # BuzzChatController's before_action calls this; for the mirror the
  # administrator permission replaces buzz.read. Keep the same tenant boundary
  # as the Team chat so an administrator never reads another tenant's channel.
  def require_read
    return head :forbidden if Current.user.employee? || !Current.user.can?('settings.write') || Current.tenant_id != Current.user.tenant_id

    authorize(:module, :dashboard_read?)
  end
end
