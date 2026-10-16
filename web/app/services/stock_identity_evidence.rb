# frozen_string_literal: true

require 'bigdecimal'

# Exact catalog evidence for a read-only suggestion. No fuzzy scores, unit
# conversions, merchant-specific aliases or stored mapping decisions.
class StockIdentityEvidence
  UNITS = /(?<![\w.])(\d+(?:\.\d+)?)\s*(grams?|g|counts?|ct|oz|ounces?|packs?|pk|mg)\b/i
  POTENCY = /(?:(THCA|CBDA|CBGA|THC|CBD|CBG|CBN)\s*)?(\d+(?:\.\d+)?)\s*%\s*(THCA|CBDA|CBGA|THC|CBD|CBG|CBN)?/i
  CLASSIFIERS = /\b(?:default title|sativa|indica|hybrid|dominant|dom|ind)\b/i
  GENERIC = %w[flower resin rosin gummy gummies oil tincture jar jars].freeze

  attr_reader :family, :packages, :potencies, :descriptors

  def self.normalized(value)
    value.to_s.unicode_normalize(:nfkc).strip.downcase
  end

  # UPC/EAN/GTIN equivalence is permitted only with a valid check digit. Never
  # turn an arbitrary numeric SKU into a cross-field barcode match.
  def self.gtin(value)
    digits = normalized(value)
    return unless digits.match?(/\A\d+\z/) && [8, 12, 13, 14].include?(digits.length) && digits.to_i.positive?

    sum = digits[0...-1].reverse.chars.each_with_index.sum { |digit, i| digit.to_i * (i.even? ? 3 : 1) }
    digits.rjust(14, '0') if (sum + digits[-1].to_i) % 10 == 0
  end

  def self.aliases(sku, barcode)
    result = []
    result << [:sku, normalized(sku)] if sku.present?
    result << [:barcode, barcode.to_s.unicode_normalize(:nfkc).strip] if barcode.present?
    [sku, barcode].each { |value| result << [:gtin, gtin(value)] if gtin(value) }
    result.uniq
  end

  def initialize(text, product_name: nil)
    text = self.class.normalized(text).gsub(/(?<=\d),(?=\d{3}(?:\D|$))/, '')
    @packages = text.scan(UNITS).map { |amount, unit| [unit_name(unit.downcase), decimal(amount)] }.uniq.sort
    text = text.gsub(UNITS, ' ')
    @potencies = {}
    text = text.gsub(POTENCY) do
      @potencies[($1.presence || $3.presence || 'unspecified').upcase] = decimal($2)
      ' '
    end
    @descriptors = text.scan(/\btier\s*\d+\b|\bindoor\b|\boutdoor\b|\blive\b/).map { |v| v.gsub(/\s+/, ' ') }.sort
    text = text.gsub(/\btier\s*\d+\b|\bindoor\b|\boutdoor\b|\blive\b/, ' ').gsub(CLASSIFIERS, ' ')
    # Preserve ratios as ordered values before treating name tokens as a set.
    text = text.gsub(/\b(\d+)\s*:\s*(\d+)\b/, 'ratio\1to\2')
    tokens = text.scan(/[[:alnum:]]+/).uniq
    product_tokens = self.class.normalized(product_name).scan(/[[:alnum:]]+/)
    if product_tokens.length > 1 && (product_tokens - tokens).empty?
      tokens.delete(product_tokens.map { |token| token[0] }.join)
    end
    @family = tokens.sort.join(' ')
    @specific = (tokens - GENERIC).any? { |token| token.match?(/[[:alpha:]]{3}/) }
  end

  def key
    [family, packages] if @specific && packages.any? && packages.all? { |_, amount| BigDecimal(amount).positive? }
  end

  def compatible?(other)
    packages == other.packages && !descriptor_conflict?(other)
  end

  def package_conflict?(other)
    left = packages.group_by(&:first)
    right = other.packages.group_by(&:first)
    return true if left.keys.intersection(right.keys).any? { |unit| left[unit] != right[unit] }

    pack_units = %w[g count oz]
    l_units = left.keys & pack_units
    r_units = right.keys & pack_units
    l_units.any? && r_units.any? && l_units != r_units
  end

  def descriptor_conflict?(other)
    return true if potencies.keys.intersection(other.potencies.keys).any? { |key| potencies[key] != other.potencies[key] }

    tiers = [descriptors.grep(/\Atier/), other.descriptors.grep(/\Atier/)]
    grows = [descriptors & %w[indoor outdoor], other.descriptors & %w[indoor outdoor]]
    [tiers, grows].any? { |left, right| left.any? && right.any? && left != right }
  end

  def package_label
    packages.map { |unit, amount| "#{amount} #{unit}" }.join(' + ')
  end

  private

  def decimal(value)
    BigDecimal(value).to_s('F').delete_suffix('.0')
  end

  def unit_name(unit)
    return 'g' if %w[g gram grams].include?(unit)
    return 'count' if %w[count counts ct pack packs pk].include?(unit)
    return 'oz' if %w[oz ounce ounces].include?(unit)

    unit
  end
end
