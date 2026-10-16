# frozen_string_literal: true

module Marketing
  class BaseController < AuthenticatedController
    before_action :require_marketing
    rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError,
      ReplyWorkflow::Invalid, with: :workflow_error

    private

    def require_marketing
      response.headers['Cache-Control'] = 'no-store'
      authorize(:module, :marketing_read?)
      head(:not_found) unless FeatureFlag.enabled?(:marketing)
    end

    def authorize_write
      authorize(:module, :marketing_write?)
    end

    def authorize_review
      authorize(:module, :marketing_review?)
    end

    def workflow_error(error)
      message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.join(', ') : error.message
      message = 'This record changed or already exists. Reload before saving.' if error.is_a?(ActiveRecord::RecordNotUnique) || error.is_a?(ActiveRecord::StaleObjectError)
      redirect_to(marketing_path, alert: message)
    end
  end
end
