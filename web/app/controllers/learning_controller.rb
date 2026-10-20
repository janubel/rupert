# frozen_string_literal: true

class LearningController < AuthenticatedController
  before_action :load_lessons

  def index
    @completed = Array(Current.user.dashboard_config_hash['learning_completed'])
    @query = params[:q].to_s.strip.first(100)
    @terms = LearningCatalog::TERMS.select { |_key, term| @query.blank? || term.join(' ').downcase.include?(@query.downcase) }
  end

  def show
    @lesson = @lessons.find { |lesson| lesson[:key] == params[:id] }
    head :not_found unless @lesson
  end

  def complete
    @lesson = @lessons.find { |lesson| lesson[:key] == params[:id] }
    return head :not_found unless @lesson

    unless params[:answer].to_s == @lesson[:answer].to_s
      flash.now[:alert] = @lesson[:explanation]
      return render :show, status: :unprocessable_entity
    end

    Current.user.with_lock do
      config = Current.user.dashboard_config_hash
      completed = Array(config['learning_completed']) | [@lesson[:key]]
      Current.user.update!(dashboard_config: config.merge('learning_completed' => completed))
    end
    redirect_to learning_index_path, notice: "Lesson complete. #{@lesson[:explanation]}"
  end

  private

  def load_lessons
    @lessons = LearningCatalog.available(Current.user)
  end
end
