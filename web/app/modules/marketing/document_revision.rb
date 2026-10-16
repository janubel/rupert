# frozen_string_literal: true

module Marketing
  class DocumentRevision < Record
    self.table_name = 'marketing_document_revisions'
    belongs_to :document
    belongs_to :actor, class_name: 'User'
    encrypts :body, :source_url
    validates :body, presence: true, length: { maximum: 20_000 }
    validates :title, :kind, :number, presence: true
    validate { same_tenant(:document) }
    validate { https_fields(:source_url) if source_url.present? }
    before_update { raise ActiveRecord::ReadOnlyRecord }
    before_destroy { raise ActiveRecord::ReadOnlyRecord }
  end
end
