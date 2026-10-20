# frozen_string_literal: true

module Internal
  class WorkspaceProvisioningController < ActionController::API
    before_action :authenticate_worker
    rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
    rescue_from ArgumentError, with: -> { head :unprocessable_entity }
    def claim
      record = WorkspaceProvisioning.claim
      record ? render(json: record) : head(:no_content)
    end

    def update
      WorkspaceProvisioning.update!(id: params[:id], lease: params[:lease], phase: params[:phase], failure_code: params[:failure_code])
      head :ok
    end

    private

    def authenticate_worker
      response.headers['Cache-Control'] = 'no-store'
      expected = ENV['RUPERT_PROVISIONER_TOKEN'].to_s
      actual = request.headers['Authorization'].to_s.delete_prefix('Bearer ')
      head :unauthorized unless WorkspaceNode.provisioning? && expected.length >= 32 && ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end
  end
end
