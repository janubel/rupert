# frozen_string_literal: true

module Finance
  # 1099 payees: who may get a 1099, which form and box, and their W-9 details (#472). The TIN is only ever shown masked.
  class TaxPayeesController < AuthenticatedController
    before_action :set_payee, only: %i[edit update]
    before_action -> { response.headers['Cache-Control'] = 'private, no-store' }

    def index
      authorize(:module, :tax_read?)
      # From January to March the year to file is last year.
      default_year = Date.current.month <= 3 ? Date.current.year - 1 : Date.current.year
      @year = params[:year].to_i.between?(2000, Date.current.year) ? params[:year].to_i : default_year
      @totals = Finance::Form1099Totals.new(year: @year)
      @can_write = Current.user.can?('tax.write')
      return unless request.format.csv?

      ActivityLogger.log('tax_payees_exported', details: "1099 totals #{@year}")
      send_data totals_csv, filename: "1099-totals-#{@year}.csv", type: 'text/csv'
    end

    def new
      authorize(:module, :tax_write?)
      @payee = Finance::TaxPayee.new(payee_key: params[:payee_key], form_type: 'nec', tax_classification: 'individual')
      @payee.legal_name ||= choices.flat_map(&:last).find { |_label, key| key == @payee.payee_key }&.first
      @choices = choices
    end

    def create
      authorize(:module, :tax_write?)
      @payee = Finance::TaxPayee.new(payee_params)
      if @payee.save
        ActivityLogger.log('tax_payee_created', subject: @payee, details: "#{@payee.legal_name} · #{@payee.form_label}")
        redirect_to finance_tax_payees_path, notice: "#{@payee.legal_name} added."
      else
        @choices = choices
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize(:module, :tax_write?)
    end

    def update
      authorize(:module, :tax_write?)
      attributes = payee_params.except(:payee_key)
      attributes = attributes.except(:tin) if attributes[:tin].blank? # blank keeps the TIN on file
      if @payee.update(attributes)
        ActivityLogger.log('tax_payee_updated', subject: @payee, details: "#{@payee.legal_name} · #{@payee.form_label}#{' · TIN changed' if @payee.saved_change_to_tin?}")
        redirect_to finance_tax_payees_path, notice: "#{@payee.legal_name} saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    STATUS_LABELS = { 'needed' => 'Needs a 1099', 'under' => 'Under threshold', 'exempt' => 'Likely exempt', 'none' => 'No 1099' }.freeze

    # For the tax preparer: totals and W-9 status, with the TIN masked.
    def totals_csv
      require 'csv'
      CSV.generate do |csv|
        csv << ['Legal name', 'Business name', 'Paid as', 'Form', 'Classification', 'TIN (masked)', 'Address', "Paid #{@year}",
                'Card payments (left out, 1099-K)', "Of which method 'other'", 'Threshold', 'Status', 'Missing']
        @totals.rows.each do |row|
          payee = row.payee
          address = [payee.address_line1, payee.address_line2, payee.city, payee.state, payee.postal_code].compact_blank.join(', ')
          csv << [payee.legal_name, payee.business_name, payee.payee_label, payee.form_label, Finance::TaxPayee::CLASSIFICATIONS[payee.tax_classification],
                  payee.masked_tin, address, cents(row.paid_cents), cents(row.card_cents), cents(row.other_method_cents),
                  cents(row.threshold_cents(@year)), STATUS_LABELS[row.status(@year)], payee.missing.join('; ')].map { |value| safe_cell(value) }
        end
      end
    end

    def cents(value) = format('%.2f', value.to_i / 100.0)

    # Spreadsheet formula injection guard.
    def safe_cell(value) = value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value

    def set_payee
      @payee = Finance::TaxPayee.find(params[:id])
    end

    def payee_params
      params.require(:tax_payee).permit(:payee_key, :legal_name, :business_name, :tax_classification, :tin_type, :tin,
        :address_line1, :address_line2, :city, :state, :postal_code, :form_type, :misc_box, :w9_received_on, :notes)
    end

    # Payees without a profile yet: vendors, contractors on staff and names on expenses in the last two years.
    def choices
      taken = Finance::TaxPayee.pluck(:payee_key).to_set
      vendors = Purchasing::Vendor.order(:name).map { |vendor| [vendor.name, "v:#{vendor.id}"] }
      contractors = People::Employee.where(employment_type: 'contractor').order(:last_name, :first_name).map { |person| [person.full_name, "e:#{person.id}"] }
      named = Finance::PayeeActivity.new(from: 2.years.ago.to_date, to: Date.current).summaries
        .select { |summary| summary.key.start_with?('p:') && summary.key != 'p:' }.map { |summary| [summary.label, summary.key] }
      [['Vendors', vendors], ['Contractors', contractors], ['Payees on expenses', named]]
        .map { |group, rows| [group, rows.reject { |_label, key| taken.include?(key) }] }.reject { |_group, rows| rows.empty? }
    end
  end
end
