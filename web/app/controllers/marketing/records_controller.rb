# frozen_string_literal: true

module Marketing
  class RecordsController < BaseController
    before_action :authorize_write

    def new
      @record = model.new
      render('marketing/records/form')
    end

    def edit
      @record = model.find(params[:id])
      render('marketing/records/form')
    end

    def create
      @record = model.new(record_params)
      @record.save!
      redirect_to(marketing_path, notice: 'Saved.')
    end

    def update
      @record = model.find(params[:id])
      attributes = record_params
      raise ReplyWorkflow::Invalid, 'Reload this record before saving.' unless attributes[:lock_version].to_s.match?(/\A\d+\z/)

      @record.update!(attributes)
      redirect_to(marketing_path, notice: 'Saved. Any earlier reply approval must be reviewed again after context changes.')
    end

    private

    def record_params
      params.require(:record).permit(*fields, :lock_version).to_h.symbolize_keys
    end
  end
end
