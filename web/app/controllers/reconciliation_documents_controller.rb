# frozen_string_literal: true

class ReconciliationDocumentsController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action do
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def index
    load_library
  rescue ReconciliationLibrary::Error => e
    @library_error = e.message
    load_library(cursor: false)
  end

  private

  def load_library(cursor: true)
    values = params.permit(:q, :source, :category, :from, :to).to_h
    values[:cursor] = params[:cursor] if cursor
    begin
      @library = ReconciliationLibrary.new(values)
    rescue ReconciliationLibrary::Error
      raise if cursor

      @library = ReconciliationLibrary.new
    end
    @entries = @library.page
    ids = @entries.select { |entry| entry.rank.zero? }.map { |entry| entry.record.id }
    @successors = ReconciliationDocument.where(supersedes_id: ids).select(:id, :supersedes_id, :metadata_json, :period_from).index_by(&:supersedes_id)
    connection = RetentionDriveConnection.first
    @drive_copies = connection ? RetentionDriveItem.where(generation: connection.generation, item_key: @entries.map(&:key)).index_by(&:item_key) : {}
  end
end
