# frozen_string_literal: true

module Marketing
  class DocumentWriter
    def self.write(document, attributes:, actor:, version: nil, review: false)
      private_input = document.visibility == 'restricted' || attributes[:visibility] == 'restricted'
      actor = CmsWriter.authorize!(actor, review ? 'marketing.review' : 'marketing.write', contacts: private_input)
      Document.transaction do
        CmsWriter.lock!(document, version)
        document.writer_checked = true
        if review
          raise ReplyWorkflow::Invalid, 'Save a document revision before review.' unless document.persisted? && document.revisions.exists?

          document.assign_attributes(status: 'reviewed', reviewed_at: Time.current, reviewed_by_id: actor.id)
          document.save!
        else
          document.assign_attributes(attributes.slice(:title, :kind, :visibility))
          document.assign_attributes(status: 'draft', reviewed_at: nil, reviewed_by_id: nil)
          document.save!
          document.revisions.create!(tenant_id: Current.tenant_id, actor_id: actor.id,
            number: document.revisions.maximum(:number).to_i + 1, title: document.title, kind: document.kind,
            body: attributes[:body], source_url: attributes[:source_url])
          document.touch
        end
        CmsWriter.event!(document, actor, review ? 'reviewed' : 'revision_saved')
        document
      end
    end
  end
end
