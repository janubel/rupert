# frozen_string_literal: true

module Api
  module V1
    class EmployeeSquareTimecardsController < EmployeeBaseController
      def index
        records = worker.square_timecards.order(id: :desc)
        records = records.where('id < ?', params[:before].to_i) if params[:before].present?
        page = records.limit(101).to_a
        render json: { data: page.first(100).map { |card| summary(card) }, next_before: page.size > 100 ? page[99].id : nil }
      end

      def show
        card = worker.square_timecards.includes(:days).find(params[:id])
        render json: { data: summary(card).merge(days: card.days.order(:worked_on).as_json(only: %i[worked_on payable_seconds])) }
      end

      private

      def summary(card)
        card.as_json(only: %i[id external_id started_at ended_at timezone payable_seconds unpaid_break_seconds hourly_rate_cents currency import_status issue]).merge(counted: card.imported_at.present?, hours: card.hours.round(2).to_s('F'))
      end
    end
  end
end
