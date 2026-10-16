# frozen_string_literal: true

module Marketing
  class DocumentsController < BaseController
    before_action :authorize_write, only: %i[new create edit update]
    before_action :set_document, only: %i[show edit update review]

    def new
      engagement = Engagement.find(params[:engagement_id])
      @record = engagement.documents.new(kind: 'brief')
      @record.body = "Purpose:\nProducts:\nAudience:\nDeliverables and due dates:\nBrand affiliation / gift disclosure:\nOffer terms:\nContent reuse permission:\n"
      prepare_form
    end

    def show
      @revisions = @document.revisions.order(number: :desc).limit(50)
      @revision = params[:revision].present? ? @document.revisions.find(params[:revision]) : @revisions.first
    end

    def edit
      @record = @document
      revision = @record.revisions.order(number: :desc).first
      @record.body = revision&.body
      @record.source_url = revision&.source_url
      prepare_form
    end

    def create
      document = Engagement.find(params[:engagement_id]).documents.new
      DocumentWriter.write(document, actor: Current.user, attributes: attributes)
      redirect_to(marketing_document_path(document), notice: 'Document revision saved.')
    end

    def update
      DocumentWriter.write(@document, actor: Current.user, attributes: attributes, version: params.dig(:cms_record, :lock_version))
      redirect_to(marketing_document_path(@document), notice: 'New revision saved; review status reset.')
    end

    def review
      DocumentWriter.write(@document, actor: Current.user, attributes: {}, version: params[:lock_version], review: true)
      redirect_to(marketing_document_path(@document), notice: 'Current document revision reviewed.')
    end

    private

    def set_document
      @document = Document.find(params[:id])
      raise Pundit::NotAuthorizedError if @document.visibility == 'restricted' && !Current.user.can?('marketing.contacts')
    end

    def attributes
      params.require(:cms_record).permit(:title, :kind, :visibility, :body, :source_url).to_h.symbolize_keys
    end

    def prepare_form
      @form_url = @record.persisted? ? marketing_document_path(@record) : marketing_engagement_documents_path(@record.engagement)
      @back_url = @record.persisted? ? marketing_document_path(@record) : marketing_engagement_path(@record.engagement)
      render('marketing/cms/form')
    end
  end
end
