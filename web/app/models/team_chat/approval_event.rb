# frozen_string_literal: true

module TeamChat
  class ApprovalEvent < ApplicationRecord
    self.table_name = 'chat_approval_events'
    include TenantScoped
    belongs_to :approval, class_name: 'TeamChat::Approval'
    def readonly? = persisted?
  end
end
