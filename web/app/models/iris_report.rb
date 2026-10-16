# frozen_string_literal: true

# Source report snapshots, never retail sales or ledger entries. Windows may
# overlap: do not sum snapshots together. Replays replace the same window.
class IrisReport < ApplicationRecord
  include TenantScoped
  encrypts :payload_json

  def payload
    JSON.parse(payload_json)
  end
end
