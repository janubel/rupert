# frozen_string_literal: true

module Finance
  # 1099 payees: who may get a 1099, which form and box, and their W-9 details (#472). The TIN is only ever shown masked.
  class TaxPayeesController < AuthenticatedController
    before_action :set_payee, only: %i[edit update]
    before_action -> { response.headers['Cache-Control'] = 'private, no-store' }

    def index
      authorize(:module, :tax_read?)
      @payees = Finance::TaxPayee.order(:legal_name).to_a
      @can_write = Current.user.can?('tax.write')
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
