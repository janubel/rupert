# frozen_string_literal: true

class LearningController < AuthenticatedController
  before_action :load_lessons
  before_action -> { response.headers['Cache-Control'] = 'no-store' }

  def index
    @completed = @journey.completed
    @query = params[:q].to_s.strip.first(100)
    @terms = LearningCatalog::TERMS.select { |_key, term| @query.blank? || term.join(' ').downcase.include?(@query.downcase) }
      .sort_by { |_key, term| term.first.downcase }.to_h
    @matching_lessons = @lessons.select { |lesson| @query.blank? || [lesson[:title], lesson[:summary], *lesson[:steps]].join(' ').downcase.include?(@query.downcase) }
  end

  def show
    @lesson = @lessons.find { |lesson| lesson[:key] == params[:id] }
    head :not_found unless @lesson
  end

  def complete
    @lesson = @lessons.find { |lesson| lesson[:key] == params[:id] }
    return head :not_found unless @lesson

    unless params[:answer].to_s == @lesson[:answer].to_s
      @answer_error = true
      return render :show, status: :unprocessable_entity
    end

    @journey.complete!(@lesson[:key])
    redirect_to learning_index_path, notice: "Lesson complete. #{@lesson[:explanation]}"
  end

  def preferences
    if params[:focus].present?
      return head :unprocessable_entity unless @journey.choose!(params[:focus].to_s)

      redirect_to learning_index_path, notice: 'Your learning path is ready. You can change it anytime.'
    elsif params[:dismiss] == '1'
      @journey.dismiss!
      redirect_to(Current.user.employee? ? employee_app_path : root_path)
    else
      head :unprocessable_entity
    end
  end

  private

  def load_lessons
    @journey = LearningJourney.new(Current.user)
    @lessons = @journey.lessons
  end
end
