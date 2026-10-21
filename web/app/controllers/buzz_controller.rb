# frozen_string_literal: true

# The Buzz card: the @rupert agent's profile, a button into the team chat, and
# what a person needs to connect their own devices. Shows public connection info
# only (relay, channel, the agent's npub); never any private key.
class BuzzController < AuthenticatedController
  def show
    authorize(:module, :dashboard_read?)
    @state = BuzzConnect.state
    @platforms = BuzzConnect.platforms
    @can_configure = Current.user.can?('settings.write')
  end
end
