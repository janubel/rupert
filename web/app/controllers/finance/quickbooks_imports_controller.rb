# frozen_string_literal: true

require 'csv'

module Finance
  # Upload a QuickBooks CSV, review what Rupert read, map its accounts, then
  # approve. Nothing becomes a journal entry, account or vendor until a person
  # with ledger-write access approves a batch; a batch can be reversed again.
  class QuickbooksImportsController < AuthenticatedController
    include ApprovedPeriodNotice

    before_action -> { authorize(:module, :finance_read?) }
    before_action -> { authorize(:module, :finance_write?) }, only: %i[create mappings approve discard reverse]
    before_action { response.headers['Cache-Control'] = 'private, no-store' }
    before_action :load_batch, only: %i[show mappings approve discard reverse rejected]

    def index
      @can_write = Current.user.can?('finance.write')
      @batches = ImportBatch.where(source: 'quickbooks').newest.limit(100).to_a
    end

    def create
      file = params[:file]
      unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size.between?(1, QuickbooksCsv::MAX_BYTES)
        raise QuickbooksImport::Error, "Choose a CSV file no larger than #{QuickbooksCsv::MAX_BYTES / 1024 / 1024} MiB."
      end

      outcome = QuickbooksImport.stage!(bytes: file.read, kind: params[:kind], filename: file.original_filename, actor: Current.user, as_of: params[:as_of])
      if outcome.created
        ActivityLogger.log('import_batch_staged', subject: outcome.batch, details: "#{outcome.batch.kind_label}: #{outcome.batch.row_count} row(s), #{outcome.batch.filename}")
        redirect_to finance_quickbooks_import_path(outcome.batch), notice: 'Read the file. Review the preview below; nothing has been added to your books.'
      else
        redirect_to finance_quickbooks_import_path(outcome.batch), notice: 'This exact file was already uploaded. Here is its batch; nothing new was staged.'
      end
    rescue QuickbooksImport::Error => e
      @batches = ImportBatch.where(source: 'quickbooks').newest.limit(100).to_a
      @can_write = true
      @form_error = e.message
      render :index, status: :unprocessable_entity
    end

    def show
      @can_write = Current.user.can?('finance.write')
      @summary = @batch.summary
      @entity_type = entity_type
      @usage = entity_type ? QuickbooksPosting.account_usage(@batch) : []
      @accounts = Finance::Account.active.ordered.to_a
      @vendors = Purchasing::Vendor.ordered.to_a if entity_type == 'vendor'
      @customers = Core::Customer.order(:first_name, :last_name).limit(2000).to_a if entity_type == 'customer'
      @suggested_cutover = QuickbooksPosting.suggested_cutover
      @native_overlap = QuickbooksPosting.native_entries_between(@batch.date_from, @batch.date_to)
      @staged_transactions = @batch.transactions.where(status: 'staged')
      @held = @staged_transactions.where.not(reason: nil).order(:txn_date, :id).limit(50).to_a
      @status_counts = @batch.transactions.group(:status).count
      @approved_overlap = approved_overlap(@staged_transactions)
      @posted_entries = @batch.transactions.where(status: 'posted').count
      @rejected_lines = @batch.lines.rejected.order(:row_no).limit(50).to_a
    end

    def mappings
      raise QuickbooksPosting::Error, 'This batch is closed; its mappings can no longer be changed here.' unless @batch.staged? || @batch.approved?

      changes = params.fetch(:mappings, {}).permit!.to_h
      saved = 0
      ImportEntityMapping.transaction do
        ImportEntityMapping.where(id: changes.keys, entity_type: entity_type).find_each do |mapping|
          attrs = changes[mapping.id.to_s]
          next unless attrs.is_a?(Hash)

          saved += 1 if apply_mapping(mapping, attrs)
        end
      end
      redirect_to finance_quickbooks_import_path(@batch, anchor: 'mapping'), notice: saved.zero? ? 'No mapping changed.' : "Saved #{saved} mapping decision#{'s' unless saved == 1}. Nothing has been posted."
    rescue QuickbooksPosting::Error, ActiveRecord::RecordInvalid => e
      message = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
      redirect_to finance_quickbooks_import_path(@batch, anchor: 'mapping'), alert: "Nothing was saved: #{message}"
    end

    def approve
      through = parse_date(params[:post_through])
      result = QuickbooksPosting.approve!(@batch, actor: Current.user, post_through: through,
        allow_resembling: params[:allow_resembling] == '1', allow_approved_periods: params[:allow_approved] == '1')
      notice = @batch.postable? ? "Posted #{result.posted} transaction#{'s' unless result.posted == 1}." : 'Approved.'
      notice += " #{result.held.values.sum} stayed staged: #{result.held.map { |reason, n| "#{n} #{reason}" }.to_sentence}." if result.held.any?
      redirect_to finance_quickbooks_import_path(@batch), notice: notice
    rescue QuickbooksPosting::Error => e
      redirect_to finance_quickbooks_import_path(@batch), alert: "Nothing was posted. #{e.message}"
    end

    def discard
      QuickbooksPosting.discard!(@batch, actor: Current.user)
      redirect_to finance_quickbooks_imports_path, notice: 'Batch discarded. The original file stays retained.'
    rescue QuickbooksPosting::Error => e
      redirect_to finance_quickbooks_import_path(@batch), alert: e.message
    end

    def reverse
      count = QuickbooksPosting.reverse!(@batch, actor: Current.user, reason: params[:reason])
      redirect_to finance_quickbooks_import_path(@batch), notice: "Reversed: #{count} journal entr#{count == 1 ? 'y' : 'ies'} voided. The original file and staged rows are kept."
    rescue QuickbooksPosting::Error, ActiveRecord::RecordInvalid => e
      redirect_to finance_quickbooks_import_path(@batch), alert: e.respond_to?(:record) ? "Nothing was reversed. #{e.record.errors.full_messages.to_sentence}" : e.message
    end

    # Rows Rupert refused, with the reason, for fixing in QuickBooks and re-exporting.
    def rejected
      rows = @batch.lines.rejected.order(:row_no)
      csv = CSV.generate do |out|
        out << ['File row', 'Reason', 'Date', 'Type', 'Number', 'Account', 'Debit', 'Credit']
        rows.find_each do |line|
          out << [line.row_no, safe(line.reason), line.txn_date, safe(line.txn_type), safe(line.doc_number), safe(line.account_name),
                  exact(line.debit_cents), exact(line.credit_cents)]
        end
      end
      send_data csv, filename: "quickbooks-batch-#{@batch.id}-rejected.csv", type: 'text/csv'
    end

    private

    def load_batch
      @batch = ImportBatch.where(source: 'quickbooks').find(params[:id])
    end

    def entity_type
      { 'journal' => 'account', 'chart_of_accounts' => 'account', 'trial_balance' => 'account', 'vendors' => 'vendor', 'customers' => 'customer' }[@batch.kind]
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    # Spreadsheet formulas typed into a cell must not run when the file is opened.
    def safe(value)
      text = value.to_s
      text.match?(/\A[=+\-@\t\r\n]/) ? "'#{text}" : text
    end

    # Integer cents to a decimal string without floating point.
    def exact(cents)
      whole, fraction = cents.abs.divmod(100)
      "#{'-' if cents.negative?}#{whole}.#{format('%02d', fraction)}"
    end

    def approved_overlap(scope)
      ranges = QuickbooksPosting.approved_ranges
      return 0 if ranges.empty?

      scope.distinct.pluck(:txn_date).count { |date| ranges.any? { |from, to| date.between?(from, to) } }
    end

    def apply_mapping(mapping, attrs)
      decision = attrs[:decision].to_s
      return false if decision.blank? || !ImportEntityMapping::DECISIONS.include?(decision)
      raise QuickbooksPosting::Error, "“#{mapping.source_name}” has posted lines; its mapping is final." if mapping_final?(mapping)

      case decision
      when 'map'
        target = target_for(mapping, attrs[:target_id])
        raise QuickbooksPosting::Error, "Choose the Rupert #{mapping.entity_type} for “#{mapping.source_name}”." unless target

        mapping.assign_attributes(decision: 'map', target_id: target.id, proposed_code: nil)
      when 'create'
        raise QuickbooksPosting::Error, 'Customers are never created from an import; map to an existing one or skip.' if mapping.entity_type == 'customer'

        mapping.assign_attributes(decision: 'create', target_id: nil, proposed_code: attrs[:proposed_code].to_s.strip.first(20).presence,
          proposed_type: attrs[:proposed_type].presence || mapping.proposed_type)
        if mapping.entity_type == 'account'
          raise QuickbooksPosting::Error, "Give “#{mapping.source_name}” a code and a type to create it." if mapping.proposed_code.blank? || mapping.proposed_type.blank?
          raise QuickbooksPosting::Error, "Account code #{mapping.proposed_code} is already in use." if Finance::Account.where('LOWER(code) = ?', mapping.proposed_code.downcase).exists?
        end
      when 'skip', 'unmapped'
        mapping.assign_attributes(decision: decision, target_id: nil)
      end
      return false unless mapping.changed?

      mapping.assign_attributes(decided_by_id: Current.user.id, decided_by_name: Current.user.display_name || Current.user.email, decided_at: Time.current)
      mapping.save!
      ActivityLogger.log('import_mapping_decided', subject: @batch, details: "#{mapping.entity_type} “#{mapping.source_name.first(80)}” → #{mapping.decision}")
      true
    end

    def mapping_final?(mapping)
      mapping.entity_type == 'account' && ImportLine.where(status: 'posted', account_name: mapping.source_name).exists?
    end

    def target_for(mapping, id)
      case mapping.entity_type
      when 'account' then Finance::Account.active.find_by(id: id)
      when 'vendor' then Purchasing::Vendor.find_by(id: id)
      when 'customer' then Core::Customer.find_by(id: id)
      end
    end
  end
end
