# frozen_string_literal: true

# Learn Rupert: lessons, definitions, the first-run welcome, page tours and the
# getting-started checklist. Every write touches only the signed-in account's
# learning preferences; nothing here grants or changes permissions.
class LearningController < AuthenticatedController
  before_action :load_lessons
  before_action -> { response.headers['Cache-Control'] = 'no-store' }

  def index
    @completed = @journey.completed
    @query = params[:q].to_s.strip.first(100)
    @terms = LearningCatalog.search_terms(@query)
    @matching_lessons = LearningCatalog.search_lessons(@lessons, @query)
    @tours = PageTours.available(Current.user)
    @checklist = GettingStartedChecklist.new(Current.user, journey: @journey)

    respond_to do |format|
      format.html
      format.json { render json: search_payload }
    end
  end

  def show
    @lesson = @lessons.find { |lesson| lesson[:key] == params[:id] }
    return head :not_found unless @lesson

    @questions = LearningCatalog.questions(@lesson)
    @wrong = []
  end

  # POST /learning/:id/complete — every question must be answered correctly in
  # one submission. Wrong answers re-render with the explanation for retry.
  def complete
    @lesson = @lessons.find { |lesson| lesson[:key] == params[:id] }
    return head :not_found unless @lesson

    @questions = LearningCatalog.questions(@lesson)
    @wrong = @questions.each_index.select { |index| submitted_answer(index) != @questions[index][:answer].to_s }
    if @wrong.any?
      @answer_error = true
      return render :show, status: :unprocessable_entity
    end

    @journey.complete!(@lesson[:key])
    notice = "Lesson complete. #{@lesson[:explanation]}"
    notice += " You’ve finished “#{@journey.focus[:label]}”." if @journey.path_complete?
    redirect_to learning_index_path, notice: notice
  end

  # GET /welcome — the first-run welcome, also reachable later from Learn Rupert.
  def welcome
    @checklist = GettingStartedChecklist.new(Current.user, journey: @journey)
    @tour = PageTours.find(Current.user.employee? ? 'employee_home' : 'dashboard')
  end

  # POST /welcome — choose a path (or skip) and go to work.
  def onboard
    if params[:focus].present?
      return redirect_to(welcome_path, alert: 'Choose one of the paths shown.') unless @journey.choose!(params[:focus].to_s)
    else
      @journey.welcome!
    end
    destination = params[:next] == 'lesson' && @journey.next_lesson ? learning_path(@journey.next_lesson[:key]) : home_path
    destination = "#{home_path}?tour=1" if params[:next] == 'tour'
    redirect_to destination, notice: params[:focus].present? ? 'Your path is ready. Lessons and definitions stay one tap away.' : nil
  end

  # GET /learning/team — read-only training overview for people who manage accounts or staff.
  def team
    return head :forbidden unless Current.user.can?('users.read') || Current.user.can?('hr.read')

    @rows = User.where(tenant_id: Current.tenant_id).ordered.map do |user|
      journey = LearningJourney.new(user)
      lessons = journey.lessons
      done = journey.completed
      latest = done.filter_map { |key| journey.completed_at(key) }.max
      { user: user, journey: journey, path: journey.focus, lessons_total: lessons.size, lessons_done: done.size,
        tours_done: journey.tours_done.size, latest: latest, welcomed: journey.welcomed? }
    end
  end

  # PATCH /learning/preferences — personal learning state only.
  def preferences
    if params[:focus].present?
      return head :unprocessable_entity unless @journey.choose!(params[:focus].to_s)

      redirect_to learning_index_path, notice: 'Your learning path is ready. You can change it anytime.'
    elsif params[:dismiss] == '1'
      @journey.dismiss!
      redirect_to home_path
    elsif params[:tour].present?
      @journey.complete_tour!(params[:tour].to_s)
      respond_to do |format|
        format.json { render json: { ok: true, tours: @journey.tours_done } }
        format.html { redirect_back(fallback_location: home_path) }
      end
    elsif params[:checklist].present?
      @journey.mark_checklist!(params[:checklist].to_s)
      redirect_back(fallback_location: home_path, notice: 'Marked done.')
    elsif params[:checklist_hidden] == '1'
      @journey.hide_checklist!
      redirect_back(fallback_location: home_path)
    elsif params[:checklist_hidden] == '0'
      @journey.show_checklist!
      redirect_to home_path
    else
      head :unprocessable_entity
    end
  rescue ArgumentError
    head :unprocessable_entity
  end

  private

  def load_lessons
    @journey = LearningJourney.new(Current.user)
    @lessons = @journey.lessons
  end

  def home_path
    Current.user.employee? ? employee_app_path : helpers.navigation_start_path
  end

  def submitted_answer(index)
    answers = params[:answers]
    return answers[index.to_s].to_s if answers.respond_to?(:[]) && answers.respond_to?(:key?)

    index.zero? ? params[:answer].to_s : ''
  end

  def search_payload
    {
      query: @query,
      lessons: @matching_lessons.first(6).map do |lesson|
        { key: lesson[:key], title: lesson[:title], summary: lesson[:summary], minutes: lesson[:minutes],
          completed: @completed.include?(lesson[:key]), url: learning_path(lesson[:key]) }
      end,
      terms: @terms.first(8).map do |key, (label, definition)|
        { key: key, label: label, definition: definition, url: learning_index_path(anchor: "term-#{key}") }
      end,
      tours: @tours.select { |tour| @query.blank? || tour.title.downcase.include?(@query.downcase) }.first(4).map do |tour|
        { key: tour.key, title: tour.title, url: "#{tour.path}?tour=1", minutes: tour.minutes, done: @journey.tour_done?(tour.key) }
      end
    }
  end
end
