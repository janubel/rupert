# frozen_string_literal: true

module Marketing
  class InfluencersController < BaseController
    before_action :authorize_write, only: %i[new create edit update]

    def index
      @page = params[:page].to_i.clamp(1, 10_000)
      scope = Influencer.includes(:owner).order(next_follow_up_at: :asc, name: :asc, id: :asc)
      scope = scope.where(stage: params[:stage]) if Influencer::STAGES.include?(params[:stage])
      scope = scope.where(next_follow_up_at: ..Time.current) if params[:due] == '1'
      if params[:q].present?
        query = "%#{Influencer.sanitize_sql_like(params[:q].to_s.first(200)).downcase}%"
        scope = scope.where('LOWER(name) LIKE :q OR LOWER(handle) LIKE :q OR LOWER(topics) LIKE :q', q: query)
      end
      @influencers = scope.offset((@page - 1) * 30).limit(31).to_a
    end

    def show
      @influencer = Influencer.find(params[:id])
      @engagements = @influencer.engagements.includes(:campaign).order(created_at: :desc).limit(31).to_a
      @interactions = @influencer.interactions.order(occurred_at: :desc, id: :desc).limit(50) if Current.user.can?('marketing.contacts')
    end

    def new
      @record = Influencer.new(owner_id: Current.user.tenant_id == Current.tenant_id ? Current.user.id : nil)
      prepare_form
    end

    def edit
      @record = Influencer.find(params[:id])
      prepare_form
    end

    def create
      record = CmsWriter.write(Influencer.new, actor: Current.user, attributes: attributes)
      redirect_to(marketing_influencer_path(record), notice: 'Influencer added.')
    end

    def update
      record = CmsWriter.write(Influencer.find(params[:id]), actor: Current.user, attributes: attributes, version: params.dig(:cms_record, :lock_version))
      redirect_to(marketing_influencer_path(record), notice: 'Influencer updated.')
    end

    private

    def attributes
      params.require(:cms_record).permit(*(CmsWriter::INFLUENCER_FIELDS + Influencer::PRIVATE_FIELDS)).to_h.symbolize_keys
    end

    def prepare_form
      @form_url = @record.persisted? ? marketing_influencer_path(@record) : marketing_influencers_path
      @back_url = @record.persisted? ? marketing_influencer_path(@record) : marketing_influencers_path
      render('marketing/cms/form')
    end
  end
end
