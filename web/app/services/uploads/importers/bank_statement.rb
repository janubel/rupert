# frozen_string_literal: true

module Uploads
  module Importers
    # Bank-exported CSV into reviewable statement lines (BankStatementImport). The
    # import reads lines only; every line still needs a person's decision on the
    # Bank transactions page before it becomes an expense or payment.
    class BankStatement < Base
      importer 'bank_statement', label: 'Bank statement CSV', source: 'Bank', permission: 'finance.write', formats: %w[csv],
        errors: [ArgumentError, ReconciliationEvidence::Error]

      def self.params_spec(_document = nil, _detection = nil)
        [
          { name: 'account_label', label: 'Account name', type: :text, required: true, maxlength: 60,
            hint: 'A name such as “Operating checking”. Never the account number.' },
          { name: 'withdrawals_positive', label: 'My bank lists withdrawals as positive numbers in one Amount column', type: :boolean, required: false,
            hint: 'Leave unticked if withdrawals are negative or there are separate Debit and Credit columns.' }
        ]
      end

      def detect(document)
        keys = document.header
        date = keys.any? { |cell| cell.match?(/date/) }
        description = keys.any? { |cell| cell.match?(/description|memo|payee|details|name/) }
        amount = keys.include?('amount') || (keys.any? { |cell| cell.match?(/debit|withdraw|money out|paid out/) } && keys.any? { |cell| cell.match?(/credit|deposit|money in|paid in/) })
        return nil unless date && description && amount

        confidence = 0.76
        confidence += 0.1 if keys.any? { |cell| cell.match?(/balance/) }
        confidence += 0.05 if keys.any? { |cell| cell.match?(/posting date|post date|check|cleared/) }
        confidence += 0.05 if document.filename.match?(/statement|bank|checking|savings|stmt/i)
        confidence -= 0.35 if keys.any? { |cell| cell.match?(/trans #|transaction type|account|split/) }
        detection('bank_statement', 'Bank statement', confidence.clamp(0.2, 0.95),
          "Columns for a date, a description and an amount (#{document.header.first(6).join(', ')}).")
      end

      def dry_run(document, params, _upload)
        # import! runs inside the workflow's always-rolled-back transaction, so the
        # counts below (new lines versus lines already seen) are exact.
        result = build(document, params).import!(filename: 'dry-run.csv', actor: Current.user)
        outcome('These lines would be added to Bank transactions as undecided. Nothing becomes an expense until you choose it there.',
          counts: { 'New lines' => result[:created], 'Already seen (skipped)' => result[:duplicates], 'First date' => result[:from].to_s, 'Last date' => result[:to].to_s })
      end

      def import!(document, params, upload, actor:)
        result = build(document, params).import!(filename: upload.filename, actor: actor)
        outcome('Statement lines are ready to review. The original file is retained unchanged.',
          counts: { 'New lines' => result[:created], 'Already seen (skipped)' => result[:duplicates], 'First date' => result[:from].to_s, 'Last date' => result[:to].to_s },
          path: helpers.bank_statement_path(result[:document].id))
      end

      private

      def build(document, params)
        ::BankStatementImport.new(bytes: text!(document), account_label: params['account_label'], withdrawals_positive: params['withdrawals_positive'] == '1')
      end
    end
  end
end
