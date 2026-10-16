# frozen_string_literal: true

class ReconciliationDocumentsController < AuthenticatedController
  include ReconciliationCloseContext
  before_action -> { authorize(:module, :reports_read?) }
  before_action do
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def index
    @report_request = ReconciliationFollowUp.includes(:owner).find(params[:follow_up]) if params[:follow_up].present?
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
    if @report_request
      load_close_context(@report_request)
    elsif params[:control_for].present?
      load_close_context(from: params[:close_day], to: params[:close_day])
    else
      load_close_context(from: @library.filters['from'], to: @library.filters['to'])
    end
    @library_context = { follow_up: @report_request&.id, close_day: @close_day&.iso8601 }.compact
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
    @request_context[:close_day] = @close_day.iso8601 if @close_day
    load_missing_control_context
    @request_match_count = @report_request ? @entries.count { |entry| entry.rank.zero? && @report_request.document_matches?(entry.record) } : 0
    ids = @entries.select { |entry| entry.rank.zero? }.map { |entry| entry.record.id }
    @document_follow_ups = @entries.select { |entry| entry.rank.zero? }.to_h do |entry|
      [entry.record.id, ReconciliationDocumentFollowUps.for(entry.record)]
    end
    @successors = ReconciliationDocument.where(supersedes_id: ids).select(:id, :supersedes_id, :metadata_json, :period_from).index_by(&:supersedes_id)
    connection = RetentionDriveConnection.first
    @drive_copies = connection ? RetentionDriveItem.where(generation: connection.generation, item_key: @entries.map(&:key)).index_by(&:item_key) : {}
  end

  def load_missing_control_context
    return if @report_request || params[:control_for].blank?

    @control_scope_changed = true
    return unless @close_day && params[:control_for].to_s.match?(/\A[0-9a-f]{64}\z/)

    @library_context[:control_for] = params[:control_for]
    workflow = FinancialCloseWorkflow.new(day: @close_day.iso8601)
    row = workflow.attention.missing_controls.find { |item| workflow.attention.control_key(item) == params[:control_for] }
    return unless row && ReconciliationDocument::SOURCES.excluding('rupert').include?(row[:source]) && row[:currency].to_s.match?(/\A[A-Z]{3}\z/)

    @control_scope_changed = false
    if (@report_request = workflow.missing_control_request(row))
      @library_context = { follow_up: @report_request.id, close_day: @close_day.iso8601 }
    else
      @missing_control = row
      @request_context = helpers.reconciliation_follow_up_context(row, @close_day, category: 'missing_report')
    end
  end
end
