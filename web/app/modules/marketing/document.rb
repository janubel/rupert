# frozen_string_literal: true

module Marketing
  class Document < Record
    self.table_name = 'marketing_documents'
    KINDS = %w[brief product_instructions agreement offer_terms disclosure content_permission outcome].freeze
    belongs_to :engagement
    has_many :revisions, class_name: 'Marketing::DocumentRevision'
    attr_accessor :writer_checked, :body, :source_url

    validates :title, presence: true, length: { maximum: 200 }
    validates :kind, inclusion: { in: KINDS }
    validates :visibility, inclusion: { in: %w[internal restricted] }
    validates :status, inclusion: { in: %w[draft reviewed] }
    validate { same_tenant(:engagement) }
    validate { errors.add(:base, 'Use the document writer') unless writer_checked }
  end
end
