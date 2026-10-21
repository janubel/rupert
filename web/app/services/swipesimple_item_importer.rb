# frozen_string_literal: true

require 'bigdecimal'
require 'csv'
require 'digest'

# Reads an item list exported from SwipeSimple (Items / Inventory → Export) and
# replaces the stored snapshot for that merchant account. Column names vary
# between SwipeSimple versions, so common names are recognised; only an item
# name is required. The whole file is validated before anything is saved.
# A missing or blank quantity stays unknown, never zero.
class SwipesimpleItemImporter
  MAX_BYTES = 5 * 1024 * 1024
  MAX_ROWS = 20_000

  # Normalised header (lowercase letters and digits only) → field.
  COLUMNS = {
    id: %w[id itemid itemnumber productid variantid variationid],
    name: %w[name itemname item product productname title],
    variant: %w[variant variantname variation variationname option options size],
    sku: %w[sku itemsku productsku variantsku code itemcode],
    barcode: %w[barcode upc ean gtin upccode],
    price: %w[price unitprice retailprice saleprice amount],
    quantity: %w[quantity qty stock instock onhand quantityonhand inventory inventorycount stockquantity available stocklevel count],
    category: %w[category categories department group itemcategory],
    tracking: %w[trackinventory trackstock inventorytracking tracked trackquantity]
  }.freeze
  NO = %w[no n false 0 off disabled].freeze

  class Error < StandardError; end

  Preview = Struct.new(:records, :mapped, :ignored, :warnings, :sha256, keyword_init: true)

  def self.preview(bytes) = new(bytes).preview

  def self.import!(bytes, merchant_account:, filename: nil, actor: Current.user)
    preview = preview(bytes)
    account = merchant_account.to_s.strip.presence || 'SwipeSimple'
    raise Error, 'Merchant account name is too long.' if account.length > 120

    snapshot = SwipesimpleItemSnapshot.find_or_initialize_by(merchant_account: account)
    snapshot.update!(records_json: preview.records, row_count: preview.records.size, sha256: preview.sha256,
      source_filename: filename.to_s[0, 255].presence, captured_at: Time.current, imported_by: actor)
    [snapshot, preview]
  end

  def initialize(bytes)
    @bytes = bytes.to_s.b
  end

  def preview
    raise Error, 'Choose a CSV file exported from SwipeSimple.' if @bytes.empty?
    raise Error, "The file is larger than #{MAX_BYTES / 1024 / 1024} MB." if @bytes.bytesize > MAX_BYTES

    table = CSV.parse(text, headers: true, skip_blanks: true)
    raise Error, "The file has more than #{MAX_ROWS} rows." if table.size > MAX_ROWS

    mapping = map_headers(table.headers)
    raise Error, 'No item name column was found (expected a column such as Name, Item or Product).' unless mapping[:name]

    warnings = []
    warnings << 'No quantity column was found, so stock is unknown for every item.' unless mapping[:quantity]
    warnings << 'No SKU or barcode column was found, so items can only be matched by exact name and package size.' unless mapping[:sku] || mapping[:barcode]
    records = table.each_with_index.filter_map { |row, index| record(row, index + 2, mapping) }
    raise Error, 'The file has no items.' if records.empty?

    duplicates = records.group_by { |r| r['id'] }.select { |_, list| list.size > 1 }.keys
    raise Error, "The same item appears more than once (#{duplicates.first(3).join(', ')}). Export again or remove duplicate rows." if duplicates.any?

    unknown = records.count { |r| r['quantity'].nil? }
    warnings << "#{unknown} item#{'s' unless unknown == 1} #{unknown == 1 ? 'has' : 'have'} no stock figure; #{unknown == 1 ? 'it stays' : 'they stay'} unknown, not zero." if mapping[:quantity] && unknown.positive?
    Preview.new(records: records, mapped: mapping.transform_values { |i| table.headers[i] }, warnings: warnings,
      ignored: table.headers.each_index.reject { |i| mapping.value?(i) }.map { |i| table.headers[i] }.compact,
      sha256: Digest::SHA256.hexdigest(@bytes))
  rescue CSV::MalformedCSVError => e
    raise Error, "The file is not a readable CSV (#{e.message.split(' in line').first})."
  end

  private

  def text
    utf8 = @bytes.dup.force_encoding(Encoding::UTF_8)
    utf8 = @bytes.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8) unless utf8.valid_encoding?
    utf8.delete_prefix("﻿")
  end

  def map_headers(headers)
    normalised = headers.map { |h| h.to_s.downcase.gsub(/[^a-z0-9]/, '') }
    COLUMNS.each_with_object({}) do |(field, names), mapping|
      index = names.lazy.filter_map { |name| normalised.index(name) }.first
      mapping[field] = index if index && !mapping.value?(index)
    end
  end

  def record(row, line, mapping)
    value = ->(field) { mapping[field] && row[mapping[field]].to_s.strip.presence }
    product = value.call(:name)
    return nil unless product

    variant = value.call(:variant)
    variant = nil if variant&.casecmp?('default') || variant&.casecmp?('regular')
    sku = value.call(:sku)
    quantity = number(value.call(:quantity), line, 'quantity')
    price = number(value.call(:price), line, 'price')
    tracking = value.call(:tracking)
    native = value.call(:id)
    identity = native || sku || "name:#{Digest::SHA256.hexdigest([product, variant].join("\u0000").downcase)[0, 16]}"
    { 'id' => identity, 'native_id' => native, 'name' => [product, variant].compact.join(' '), 'product_name' => product,
      'variant' => variant, 'sku' => sku, 'barcode' => value.call(:barcode), 'price' => price&.to_s('F'), 'price_cents' => price && (price * 100).round.to_i,
      'quantity' => quantity&.to_s('F')&.delete_suffix('.0'), 'manage_stock' => !quantity.nil? && !NO.include?(tracking.to_s.downcase),
      'category' => value.call(:category), 'line' => line }
  end

  def number(raw, line, label)
    return nil if raw.nil?

    cleaned = raw.delete('$, ')
    cleaned = "-#{cleaned[1..-2]}" if cleaned.match?(/\A\(.*\)\z/)
    raise Error, "Row #{line}: #{label} \"#{raw[0, 20]}\" is not a number." unless cleaned.match?(/\A-?\d+(\.\d+)?\z/)

    BigDecimal(cleaned)
  end
end
