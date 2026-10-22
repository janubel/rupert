# frozen_string_literal: true

# The operator's explicit decision about an outside account, vendor or customer:
# map it to an existing Rupert record, create a new one on approval, or skip it.
# A suggestion is never a decision.
class ImportEntityMapping < ApplicationRecord
  include TenantScoped

  ENTITY_TYPES = %w[account vendor customer].freeze
  DECISIONS = %w[unmapped map create skip].freeze

  validates :source, inclusion: { in: ImportSourceDocument::SOURCES }
  validates :entity_type, inclusion: { in: ENTITY_TYPES }
  validates :decision, inclusion: { in: DECISIONS }
  validates :source_key, :source_name, presence: true
  validates :target_id, presence: true, if: -> { decision == 'map' }
  validates :proposed_code, :proposed_type, presence: true, if: -> { decision == 'create' && entity_type == 'account' }
  validates :proposed_type, inclusion: { in: Finance::Account::TYPES }, allow_blank: true

  scope :accounts, -> { where(entity_type: 'account') }

  def self.key_for(name) = name.to_s.unicode_normalize(:nfkc).squish.downcase

  def decided? = decision != 'unmapped'
  def target_account = (Finance::Account.find_by(id: target_id) if entity_type == 'account' && target_id)
end
