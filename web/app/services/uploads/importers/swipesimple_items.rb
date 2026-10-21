# frozen_string_literal: true

module Uploads
  module Importers
    # A SwipeSimple item list (SwipesimpleItemImporter): replaces that merchant
    # account's item snapshot used for stock comparison. It never writes to SwipeSimple.
    class SwipesimpleItems < Base
      importer 'swipesimple_items', label: 'SwipeSimple item list', source: 'SwipeSimple', permission: 'inventory.write', formats: %w[csv],
        errors: [ArgumentError, ::SwipesimpleItemImporter::Error]

      def self.destination_label = 'SwipeSimple items'

      def self.params_spec(_document = nil, _detection = nil)
        [{ name: 'merchant_account', label: 'Merchant account name', type: :text, required: false, maxlength: 120,
           hint: 'Which SwipeSimple account this list belongs to. Leave blank for the default “SwipeSimple”.' }]
      end

      def detect(document)
        keys = document.header_keys
        return nil if keys.any? { |key| %w[date transactionid transaction orderid debit credit amountpaid].include?(key) }

        columns = ::SwipesimpleItemImporter::COLUMNS
        name = keys.any? { |key| columns[:name].include?(key) }
        others = %i[sku barcode price quantity category tracking].select { |field| keys.any? { |key| columns[field].include?(key) } }
        return nil unless name && others.size >= 2

        confidence = 0.55 + (others.size * 0.04)
        confidence += 0.15 if document.filename.match?(/swipe|item|inventory|catalog/i)
        detection('swipesimple_items', 'SwipeSimple item list', confidence,
          "An item name column plus #{others.to_sentence} (#{document.header.first(6).join(', ')}). The columns are generic, so this is a shape match, not a signature.")
      end

      def dry_run(document, params, _upload)
        preview = ::SwipesimpleItemImporter.preview(document.bytes)
        account = params['merchant_account'].to_s.strip.presence || 'SwipeSimple'
        raise ArgumentError, 'Merchant account name is too long.' if account.length > 120

        outcome("Would replace the item snapshot for “#{account}” with these items. Nothing is sent to SwipeSimple.",
          counts: { 'Items' => preview.records.size, 'Columns read' => preview.mapped.size, 'Columns ignored' => preview.ignored.size },
          warnings: preview.warnings)
      end

      def import!(document, params, upload, actor:)
        snapshot, preview = ::SwipesimpleItemImporter.import!(document.bytes, merchant_account: params['merchant_account'], filename: upload.filename, actor: actor)
        outcome("Item snapshot saved for “#{snapshot.merchant_account}”.", counts: { 'Items' => preview.records.size },
          warnings: preview.warnings, path: helpers.swipesimple_items_path)
      end
    end
  end
end
