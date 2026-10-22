# frozen_string_literal: true

# One operator-supplied bank CSV of Zelle activity. Immutable evidence: the
# exact bytes are kept encrypted and are never edited after import.
class ZelleExport < ApplicationRecord
  include TenantScoped

  encrypts :original_csv
  belongs_to :imported_by, class_name: 'User', optional: true
  has_many :entries, class_name: 'ZelleEntry', dependent: :restrict_with_exception
  validates :tenant_id, :account_label, :fingerprint, :sha256, :exported_at, presence: true
  validates :currency, inclusion: { in: %w[USD] }
end
