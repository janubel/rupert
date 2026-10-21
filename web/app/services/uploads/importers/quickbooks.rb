# frozen_string_literal: true

module Uploads
  module Importers
    # QuickBooks (Online or Desktop) CSV exports. Sniffing lives here and works on
    # its own; reading and staging belong to QuickbooksCsv / QuickbooksImport (the
    # History import). This importer only STAGES a file for review: the History
    # page keeps its own approve, post and reverse steps, so nothing reaches the
    # books from the inbox.
    class Quickbooks < Base
      importer 'quickbooks', label: 'QuickBooks CSV (stage for review)', source: 'QuickBooks', permission: 'finance.write',
        formats: %w[csv], errors: [ArgumentError]

      KINDS = {
        'chart_of_accounts' => 'Chart of accounts (Account List)',
        'journal' => 'Journal, general ledger or transaction detail',
        'vendors' => 'Vendor list',
        'customers' => 'Customer list',
        'trial_balance' => 'Trial balance'
      }.freeze

      TITLES = {
        'trial_balance' => /trial balance/i,
        'journal' => /\bjournal\b|general ledger|transaction detail|transaction list by date/i,
        'chart_of_accounts' => /account list|chart of accounts/i,
        'vendors' => /vendor (contact )?list|vendor center/i,
        'customers' => /customer (contact )?list|customer center/i
      }.freeze

      def self.available? = defined?(::QuickbooksImport) && defined?(::QuickbooksCsv) ? true : false

      def self.kind_of_type(type) = type.to_s.delete_prefix('quickbooks:')

      def self.params_spec(_document = nil, detection = nil)
        return [] unless kind_of_type(detection&.type) == 'trial_balance'

        [{ name: 'as_of', label: 'Trial balance “as of” date', type: :text, required: true, hint: 'YYYY-MM-DD, the date printed on the report.' }]
      end

      # Pure sniffing, shared with the detect-only Recognized importer so an
      # Excel copy of a QuickBooks report is at least named correctly.
      def self.classify(document)
        titles = document.rows(8).first(8).flatten.map { |cell| cell.to_s.strip }.reject(&:empty?)
        title_kind = TITLES.find { |_kind, pattern| titles.any? { |cell| cell.length < 90 && cell.match?(pattern) } }&.first
        keys = document.header_keys
        shape = shape_kind(keys)
        quickbooks_marks = titles.any? { |cell| cell.match?(/accrual basis|cash basis|quickbooks|accounting method/i) } ||
                           keys.include?('trans') || keys.include?('memodescription') || keys.include?('detailtype') || keys.include?('accnt')
        return nil unless title_kind || shape

        kind = title_kind || shape
        # General Ledger and Transaction Detail by Account carry one signed Amount
        # column; the QuickBooks import posts only Debit and Credit layouts.
        signed_only = kind == 'journal' && !(keys.include?('debit') && keys.include?('credit'))
        result = describe(document, kind, title_kind, shape, quickbooks_marks)
        return result unless signed_only

        [kind, [result[1], 0.7].min, "#{result[2]} It has no separate Debit and Credit columns, which the QuickBooks import cannot post; the dry run will explain."]
      end

      def self.describe(document, kind, title_kind, shape, quickbooks_marks)
        if title_kind && shape && title_kind == shape
          [kind, quickbooks_marks ? 0.95 : 0.88, "The report title and the columns (#{document.header.first(6).join(', ')}) both say #{KINDS.fetch(kind).downcase}."]
        elsif title_kind
          [kind, 0.8, "A title near the top of the file says #{KINDS.fetch(kind).downcase}, but the columns do not fully confirm it."]
        else
          [kind, quickbooks_marks ? 0.78 : 0.45, "The columns (#{document.header.first(6).join(', ')}) look like a #{KINDS.fetch(kind).downcase}#{quickbooks_marks ? '' : ', but nothing marks the file as QuickBooks'}."]
        end
      end

      def self.shape_kind(keys)
        has = ->(*names) { names.all? { |name| keys.include?(name) } }
        any = ->(*names) { names.any? { |name| keys.include?(name) } }
        if has.call('account') && any.call('type', 'accounttype') && any.call('detailtype', 'accnt', 'balancetotal', 'description') && !any.call('date', 'debit', 'credit')
          'chart_of_accounts'
        elsif has.call('date', 'account') && (has.call('debit', 'credit') || any.call('amount', 'split', 'transactiontype', 'trans')) && any.call('memodescription', 'memo', 'name')
          'journal'
        elsif has.call('debit', 'credit') && !any.call('date', 'num', 'memo', 'memodescription')
          'trial_balance'
        elsif any.call('vendor') && any.call('balance', 'openbalance', 'balancetotal', 'phone', 'email', 'companyname', 'company') && !any.call('date', 'debit', 'credit')
          'vendors'
        elsif any.call('customer') && any.call('balance', 'openbalance', 'balancetotal', 'phone', 'phonenumbers', 'email', 'billaddress', 'fullname') && !any.call('date', 'debit', 'credit')
          'customers'
        end
      end

      def detect(document)
        kind, confidence, reason = self.class.classify(document)
        return nil unless kind

        detection("quickbooks:#{kind}", "QuickBooks — #{KINDS.fetch(kind)}", confidence, reason)
      end

      def suggested_params(document, detection)
        return {} unless self.class.kind_of_type(detection.type) == 'trial_balance'

        text = document.rows(8).first(8).map { |row| row.join(',') }.join(' ')
        date = text[/as of\s+([A-Za-z]+\s+\d{1,2},\s*\d{4})/i, 1]
        iso = date && Date.strptime(date.squish, '%B %d, %Y').iso8601
        iso ? { 'as_of' => iso } : {}
      rescue Date::Error
        {}
      end

      def dry_run(document, params, upload)
        kind = self.class.kind_of_type(upload.detected_type)
        parsed = ::QuickbooksCsv.parse(document.bytes, kind: kind)
        rejected = parsed.rows.count(&:rejected?)
        dates = parsed.rows.reject(&:rejected?).filter_map(&:date)
        counts = { 'Rows read' => parsed.rows.size, 'Rows that cannot be read' => rejected }
        counts['Dates from'] = dates.min.to_s if dates.any?
        counts['Dates to'] = dates.max.to_s if dates.any?
        check_as_of!(kind, params)
        outcome("Reads as a #{KINDS.fetch(kind).downcase}. Approving stages it on the History page for review; it does not post to the books.",
          counts: counts, warnings: Array(parsed.notes).first(10).map(&:to_s))
      rescue ::QuickbooksCsv::Error => e
        raise ArgumentError, e.message
      end

      def import!(document, params, upload, actor:)
        kind = self.class.kind_of_type(upload.detected_type)
        check_as_of!(kind, params)
        result = ::QuickbooksImport.stage!(bytes: document.bytes, kind: kind, filename: upload.filename, actor: actor, as_of: params['as_of'])
        batch = result.batch
        path = helpers.respond_to?(:finance_quickbooks_import_path) ? helpers.finance_quickbooks_import_path(batch) : nil
        outcome(result.created ? 'Staged for review on the History page. Nothing was posted to the books.' : 'This file was already staged; opened the existing batch.',
          counts: { 'Rows' => batch.row_count, 'Accepted' => batch.accepted_count, 'Duplicates' => batch.duplicate_count, 'Rejected' => batch.rejected_count }, path: path)
      rescue ::QuickbooksImport::Error => e
        raise ArgumentError, e.message
      end

      private

      def check_as_of!(kind, params)
        return unless kind == 'trial_balance'

        raise ArgumentError, 'Enter the “as of” date of the trial balance (YYYY-MM-DD).' unless params['as_of'].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      end
    end
  end
end
