# frozen_string_literal: true

class BulkInventoryController < AuthenticatedController
  before_action :authorize_inventory_read
  before_action :authorize_inventory_write, if: -> { %w[new create].include?(action_name) }

  rescue_from ActiveRecord::StatementInvalid, with: :handle_database_error

  private

  def authorize_inventory_read
    authorize(:module, :inventory_read?)
  end

  def authorize_inventory_write
    authorize(:module, :inventory_write?)
  end

  def handle_database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause.class.name)

    redirect_to(bulk_materials_path, alert: 'The bulk ledger is busy. Please retry; this change was not saved.')
  end
end
