# frozen_string_literal: true

class ApiAccessTokensController < AuthenticatedController
  before_action :authorize_management
  before_action :prevent_caching

  def index
    @token = ApiAccessToken.new(expires_at: 90.days.from_now)
    load_tokens
  end

  def create
    @token, @issued_secret = ApiAccessToken.issue(attributes: token_params.to_h.symbolize_keys,
      user: Current.user, tenant: Current.tenant)
    load_tokens
    render :index, status: @token.persisted? ? :created : :unprocessable_entity
  end

  def revoke
    token = ApiAccessToken.find(params[:id])
    token.update!(revoked_at: Time.current) unless token.revoked_at
    redirect_to api_access_tokens_path, notice: 'API token revoked.'
  end

  private

  def authorize_management
    authorize(:module, :settings_write?)
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end

  def token_params
    params.require(:api_access_token).permit(:name, :expires_at, scopes: [])
  end

  def load_tokens
    @pagy, @tokens = pagy(ApiAccessToken.includes(:user).order(created_at: :desc, id: :desc), items: 30)
  end
end
