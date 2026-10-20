# frozen_string_literal: true

module Goals
  class KpisController < AuthenticatedController
    before_action :set_kpi, only: %i[show update destroy]

    def index
      authorize(:module, :projects_read?)
      @q = Goals::Kpi.ransack(params[:q])
      @pagy, @kpis = pagy(@q.result.includes(:readings).order(updated_at: :desc), items: 20)
    end

    def show
      authorize(@kpi)
    end

    def new
      authorize(:module, :projects_write?)
      @kpi = Goals::Kpi.new
    end

    def create
      authorize(:module, :projects_write?)
      @kpi = Goals::Kpi.new(kpi_params)
      if @kpi.save
        redirect_to(@kpi, notice: 'KPI created.')
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(@kpi)
    end

    def update
      authorize(@kpi)
      if @kpi.update(kpi_params)
        redirect_to(@kpi, notice: 'KPI updated.')
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(@kpi)
      @kpi.destroy
      redirect_to(kpis_path, notice: 'KPI deleted.')
    end

    # POST /kpis/:id/reading — record a new measurement
    def reading
      authorize(:module, :projects_write?)
      @kpi = Goals::Kpi.find(params[:id])
      measured_at = parse_measured_at(params[:measured_at])
      return redirect_to(@kpi, alert: 'Enter the measurement date and time as a real date, for example 2026-10-20 14:30.') if measured_at.nil?

      @kpi.readings.create!(value: params[:value], measured_at: measured_at)
      redirect_to(@kpi, notice: 'Reading recorded.')
    rescue ActiveRecord::RecordInvalid => e
      redirect_to(@kpi, alert: e.message)
    end

    private

    # Blank means "now". Anything else must parse as a real timestamp: Time.zone.parse
    # returns nil for text it cannot read and raises ArgumentError for out-of-range
    # parts such as a 13th month, which previously surfaced as a 500.
    def parse_measured_at(value)
      return Time.current if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def set_kpi
      @kpi = Goals::Kpi.find(params[:id])
    end

    def kpi_params
      params.require(:kpi).permit(:name, :unit, :target_value, :direction)
    end
  end
end
