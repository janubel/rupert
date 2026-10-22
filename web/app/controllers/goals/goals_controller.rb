# frozen_string_literal: true

module Goals
  class GoalsController < AuthenticatedController
    before_action :set_goal, only: %i[show update destroy transition]

    def index
      authorize(:module, :projects_read?)
      @q = Goals::Goal.ransack(params[:q])
      @pagy, @goals = pagy(:offset, @q.result.order(updated_at: :desc), limit: 20)
    end

    def show
      authorize(@goal)
    end

    def new
      authorize(:module, :projects_write?)
      @goal = Goals::Goal.new
    end

    def create
      authorize(:module, :projects_write?)
      @goal = Goals::Goal.new(goal_params)
      if @goal.save
        redirect_to(@goal, notice: 'Goal created.')
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(@goal)
    end

    def update
      authorize(@goal)
      if @goal.update(goal_params)
        redirect_to(@goal, notice: 'Goal updated.')
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(@goal)
      @goal.destroy
      redirect_to(goals_path, notice: 'Goal deleted.')
    end

    # POST /goals/:id/transition?event=activate|achieve|abandon
    def transition
      authorize(@goal)
      event = params[:event]
      if %w[activate achieve abandon].include?(event) && @goal.public_send("may_#{event}?")
        @goal.send("#{event}!")
        redirect_to(@goal, notice: "Goal #{event}d.")
      else
        redirect_to(@goal, alert: "Cannot #{event} a #{@goal.status} goal.")
      end
    end

    private

    def set_goal
      @goal = Goals::Goal.find(params[:id])
    end

    def goal_params
      params.require(:goal).permit(:name, :description, :unit, :target_value, :current_value, :due_on)
    end
  end
end
