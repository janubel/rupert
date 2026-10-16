# frozen_string_literal: true

class AddNmiSandboxCheckout < ActiveRecord::Migration[8.0]
  def change
    add_column :pos_settings, :gateway_provider, :string, null: false, default: 'authorize_net'
    add_column :pos_checkouts, :gateway_provider, :string, null: false, default: 'authorize_net'
    add_column :pos_checkouts, :gateway_fingerprint, :string
  end
end
