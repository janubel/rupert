# frozen_string_literal: true

module Marketing
  class RepliesController < BaseController
    def new
      authorize_write
      thread = Thread.find(params[:thread_id])
      return redirect_to(marketing_reply_path(thread.reply)) if thread.reply

      @reply = Reply.new(thread: thread)
      render(:show)
    end

    def show
      @reply = Reply.find(params[:id])
    end

    def create
      authorize_write
      @reply = Reply.new(thread: Thread.find(params.require(:reply).fetch(:thread_id)))
      ReplyWorkflow.call(@reply, action: 'save', actor: Current.user, attributes: reply_params)
      redirect_to(marketing_reply_path(@reply), notice: 'Draft saved.')
    end

    def update
      authorize_write
      reply = Reply.find(params[:id])
      ReplyWorkflow.call(reply, action: 'save', actor: Current.user, version: params.require(:reply).fetch(:lock_version), attributes: reply_params)
      redirect_to(marketing_reply_path(reply), notice: 'Draft saved. Submit it for a fresh review.')
    end

    def transition
      reply = Reply.find(params[:id])
      action = params[:transition].to_s
      if action == 'publish' && params[:exact_text] != '1'
        raise ReplyWorkflow::Invalid, 'Confirm the published text matches the approved copy. Submit changed wording for review first.'
      end
      result = ReplyWorkflow.call(reply, action: action, actor: Current.user, version: params[:lock_version],
        note: params[:note], published_url: params[:published_url])
      if action == 'copy'
        @copy = result
        @reply = reply
        render(:copy)
      else
        redirect_to(marketing_reply_path(reply), notice: 'Reply workflow updated.')
      end
    end

    private

    def reply_params
      params.require(:reply).permit(:body, :affiliation, :offer_id).to_h.symbolize_keys
    end
  end
end
