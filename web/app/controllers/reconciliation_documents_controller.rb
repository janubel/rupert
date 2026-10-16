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
    @follow_up_count = ReconciliationFollowUp.active.count
    @overdue_count = ReconciliationFollowUp.active.where('due_on < ?', Date.current).count
    @today_count = ReconciliationFollowUp.active.where(due_on: Date.current).count
    @entries = @library.page
    @request_context = @library.filters.slice('source').compact_blank
    @request_context = {} if @request_context['source'] == 'rupert'
    from, to = @library.filters.values_at('from', 'to')
    if from.present? && to.present? && (Date.iso8601(to) - Date.iso8601(from)).between?(0, 365)
      @request_context.merge!(period_from: from, period_to: to)
    end
    ids = @entries.select { |entry| entry.rank.zero? }.map { |entry| entry.record.id }
    @document_follow_ups = @entries.select { |entry| entry.rank.zero? }.to_h do |entry|
      [entry.record.id, ReconciliationDocumentFollowUps.for(entry.record)]
    end
    @successors = ReconciliationDocument.where(supersedes_id: ids).select(:id, :supersedes_id, :metadata_json, :period_from).index_by(&:supersedes_id)
    connection = RetentionDriveConnection.first
    @drive_copies = connection ? RetentionDriveItem.where(generation: connection.generation, item_key: @entries.map(&:key)).index_by(&:item_key) : {}
  end
end
