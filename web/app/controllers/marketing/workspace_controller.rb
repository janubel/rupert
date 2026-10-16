# frozen_string_literal: true

module Marketing
  class WorkspaceController < BaseController
    skip_before_action :require_marketing, only: %i[index toggle]

    def index
      response.headers['Cache-Control'] = 'no-store'
      authorize(:module, :marketing_read?)
      @enabled = FeatureFlag.enabled?(:marketing)
      return unless @enabled

      @campaigns = Campaign.order(:name).limit(201).to_a
      @communities = Community.includes(:campaign).order(:name).limit(201).to_a
      @offers = Offer.where.not(community_id: nil).includes(community: :campaign).order(created_at: :desc).limit(31).to_a
      @pending = Reply.includes(:thread).where(status: 'pending_review').order(updated_at: :asc).limit(31).to_a
      @page = params[:page].to_i.clamp(1, 10_000)
      scope = Thread.includes(:community, :reply).order(created_at: :desc, id: :desc)
      scope = scope.where(community_id: params[:community_id]) if params[:community_id].present?
      if %w[new relevant dismissed snoozed].include?(params[:status])
        scope = scope.where(status: params[:status])
      else
        scope = scope.where.not(status: 'snoozed').or(scope.where(status: 'snoozed', snoozed_until: ..Time.current))
      end
      if params[:q].present?
        query = "%#{Thread.sanitize_sql_like(params[:q].to_s.first(200))}%"
        scope = scope.where('LOWER(title) LIKE :q OR LOWER(excerpt) LIKE :q', q: query.downcase)
      end
      @threads = scope.offset((@page - 1) * 30).limit(31).to_a
    end

    def toggle
      raise Pundit::NotAuthorizedError unless Current.user.can_manage_accounts? && Current.user.can?('settings.write')

      FeatureFlag.set(:marketing, params[:enabled] == '1')
      ActivityLogger.log('marketing.toggle', details: { enabled: params[:enabled] == '1' })
      redirect_to(marketing_path, notice: 'Marketing setting updated.')
    end
  end
end
