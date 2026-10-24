# frozen_string_literal: true

module Finance
  # Who may get a 1099 and their W-9 details (#472). A payee is keyed like Finance::PayeeActivity ("v:12" a vendor,
  # "p:name" a free-text expense payee) or "e:ID" for a contractor on staff. The TIN is encrypted and shown only as its
  # last four digits; reading it needs tax.read.
  class TaxPayee < ApplicationRecord
    include TenantScoped

    self.table_name = 'tax_payees'

    CLASSIFICATIONS = {
      'individual' => 'Individual or sole proprietor', 'llc_single' => 'Single-member LLC',
      'partnership' => 'Partnership', 'llc_partnership' => 'LLC taxed as a partnership',
      'c_corporation' => 'C corporation', 's_corporation' => 'S corporation', 'llc_corporation' => 'LLC taxed as a corporation',
      'trust' => 'Trust or estate', 'other' => 'Other'
    }.freeze
    CORPORATIONS = %w[c_corporation s_corporation llc_corporation].freeze
    FORMS = { 'nec' => '1099-NEC', 'misc' => '1099-MISC', 'none' => 'No 1099' }.freeze
    MISC_BOXES = { '1' => 'Box 1 · Rents', '2' => 'Box 2 · Royalties', '3' => 'Box 3 · Other income',
                   '6' => 'Box 6 · Medical and health care payments', '10' => 'Box 10 · Gross proceeds paid to an attorney' }.freeze
    TIN_TYPES = { 'ssn' => 'SSN', 'ein' => 'EIN', 'itin' => 'ITIN' }.freeze
    KEY = /\A(v:\d+|e:\d+|p:.{1,200})\z/

    encrypts :tin

    validates :payee_key, presence: true, format: { with: KEY }, uniqueness: { scope: :tenant_id }
    validates :legal_name, presence: true, length: { maximum: 200 }
    validates :business_name, length: { maximum: 200 }
    validates :tax_classification, inclusion: { in: CLASSIFICATIONS.keys }
    validates :form_type, inclusion: { in: FORMS.keys }
    validates :misc_box, inclusion: { in: MISC_BOXES.keys }, if: -> { form_type == 'misc' }
    validates :tin_type, inclusion: { in: TIN_TYPES.keys }, allow_blank: true
    validates :state, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true
    validates :postal_code, format: { with: /\A\d{5}(-\d{4})?\z/ }, allow_blank: true
    validate :tin_is_nine_digits

    before_validation :normalize

    # Shown in place of the TIN everywhere.
    def masked_tin = tin_last4.present? ? "•••-••-#{tin_last4}" : nil

    # Corporations are generally exempt from 1099-NEC/MISC, except attorney fees (MISC box 10).
    def likely_exempt? = CORPORATIONS.include?(tax_classification) && !(form_type == 'misc' && misc_box == '10')

    def form_label = form_type == 'misc' ? "#{FORMS['misc']} · #{MISC_BOXES[misc_box]}" : FORMS[form_type]

    def missing
      [('W-9' unless w9_received_on), ('TIN' if tin.blank?), ('address' if [address_line1, city, state, postal_code].any?(&:blank?))].compact
    end

    # The name payments are recorded under, for the list.
    def payee_label
      case payee_key
      when /\Av:(\d+)\z/ then Purchasing::Vendor.find_by(id: Regexp.last_match(1))&.name || "Vendor ##{Regexp.last_match(1)}"
      when /\Ae:(\d+)\z/ then People::Employee.find_by(id: Regexp.last_match(1))&.full_name || "Contractor ##{Regexp.last_match(1)}"
      else payee_key.delete_prefix('p:')
      end
    end

    private

    def normalize
      self.state = state.to_s.strip.upcase.presence
      self.postal_code = postal_code.to_s.strip.presence
      self.misc_box = nil unless form_type == 'misc'
      return unless will_save_change_to_tin?

      digits = tin.to_s.gsub(/\D/, '')
      self.tin = digits.presence
      self.tin_last4 = digits.length == 9 ? digits.last(4) : nil
    end

    def tin_is_nine_digits
      errors.add(:tin, 'must be 9 digits') if tin.present? && tin.length != 9
      errors.add(:tin_type, 'is needed with a TIN') if tin.present? && tin_type.blank?
    end
  end
end
