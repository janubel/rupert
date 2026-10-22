# frozen_string_literal: true

module TeamChatHelper
  # data-presence-user (and data-presence="active|recent" when there is something to show)
  # for an avatar, so the "recently active" dot renders at once and the page can refresh it.
  def presence_attrs(user)
    return '' unless user

    @presence_statuses ||= TeamChat::Presence.statuses(TeamChat::Post.mentionable)
    status = @presence_statuses[user.id]
    tag.attributes('data-presence-user': user.id, 'data-presence': status&.dig(:state), 'data-presence-label': status&.dig(:label))
  end
end
