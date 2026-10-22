# frozen_string_literal: true

class OperationsBriefJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(kind)
    Tenant.where(status: 'active').find_each do |tenant|
      Current.tenant = tenant
      begin
        OperationsBrief.publish!(kind) if TeamChat::Notices.configured?
      ensure
        Current.tenant = nil
      end
    end
  end
end
