# frozen_string_literal: true

# Links the signed-in person's Buzz account to their Rupert account, so the
# @rupert agent can answer them as themselves. The person makes a code here,
# sends it to the agent in a direct message in Buzz, then confirms the key here.
# Everyone can only see and change their own links.
class BuzzLinksController < AuthenticatedController
  before_action :require_available
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :load_link, only: %i[confirm destroy]

  def create
    _, code = BuzzIdentity.issue_code!(Current.user)
    ActivityLogger.log('buzz_link_code_made', details: 'code made in Rupert')
    flash[:buzz_link_code] = code
    redirect_to buzz_path(anchor: 'buzz-link')
  end

  def confirm
    if @link.confirm!
      ActivityLogger.log('buzz_link_confirmed', details: "key=#{@link.pubkey.first(8)}")
      redirect_to buzz_path(anchor: 'buzz-link'), notice: 'Linked. The @rupert agent will now answer you in Buzz as you.'
    else
      redirect_to buzz_path(anchor: 'buzz-link'), alert: 'That link can no longer be confirmed. Make a new code.'
    end
  end

  # Removes a link, declines a waiting one, or cancels an unused code.
  def destroy
    @link.revoke!
    ActivityLogger.log('buzz_link_removed', details: "key=#{@link.pubkey.to_s.first(8)}; was=#{@link.status_before_last_save}")
    redirect_to buzz_path(anchor: 'buzz-link'), notice: 'Removed.'
  end

  private

  def require_available
    return head :not_found unless AskRupert::Config.current.buzz_enabled?

    head :forbidden unless BuzzIdentity.eligible?(Current.user)
  end

  def load_link
    @link = BuzzIdentity.where(user_id: Current.user.id).where.not(status: 'revoked').find_by(id: params[:id])
    redirect_to buzz_path, alert: 'That link is gone.' unless @link
  end
end
