# frozen_string_literal: true

# Test questions (Team chat → Model scores → Test questions): the question sets that score the bots, as this
# workspace asks them. People who know the books can add questions, reword or remove built-in ones (the original
# stays in config/team_chat/battery*.yml and comes back with Restore) and start a test run on a bot. An edited set
# is scored under its own name, so its results are never mixed with the built-in questions.
class TeamChatQuestionsController < AuthenticatedController
  before_action :require_access
  before_action :load_set

  # GET /chat/models/questions?set=finance
  def index
    @sets = TeamChat::Battery.sets
    @builtin = TeamChat::Battery.builtin_items(TeamChat::Battery.config_for(@set)).index_by(&:id)
    @edits = TeamChat::Battery.edits_for(@set).index_by(&:question_id)
    @items = TeamChat::Battery.items(TeamChat::Battery.config_for(@set))
    @removed = @edits.values.reject(&:active?).filter_map { |edit| @builtin[edit.question_id] }
    @run_set = TeamChat::Battery.run_set_name(@set)
    @runs = TeamChat::BatteryRun.where(set_name: [@run_set, "#{@run_set}+verify"]).newest_first.limit(8).to_a
    @running = TeamChat::BatteryRun.where(status: 'running', started_at: 3.hours.ago..).newest_first.first
    @bots = [['@rupert', 'rupert']] + TeamChat::LocalAgents.all.map { |agent| ["@#{agent.handle} · #{agent.about}", agent.handle] } +
            (TeamChat::LocalAgents.enabled? ? TeamChat::LocalAgents::TRIALS.map { |agent| ["#{agent.name} (test only)", agent.handle] } : [])
    @tools = Mcp::Registry.tools.select(&:read_only).map(&:tool_name).sort
  end

  # POST /chat/models/questions { set, question, expect, cadence, area, checks, needs }
  def create
    id = params[:question_id].to_s.strip.downcase.presence || next_id
    save_edit(TeamChat::BatteryQuestion.new(set_name: @set, question_id: id), 'Question added.')
  end

  # PATCH /chat/models/questions/:question_id — edits a question; for a built-in one, saves the workspace's own copy.
  def update
    edit = TeamChat::BatteryQuestion.find_or_initialize_by(set_name: @set, question_id: params[:question_id].to_s)
    save_edit(edit, 'Question saved. Runs of this set are now scored as an edited set.')
  end

  # POST /chat/models/questions/:question_id/remove — leaves a built-in question out of this workspace's set.
  def remove
    edit = TeamChat::BatteryQuestion.find_or_initialize_by(set_name: @set, question_id: params[:question_id].to_s)
    edit.update!(status: 'removed', updated_by: Current.user)
    log_change('removed', edit)
    redirect_to team_chat_questions_path(set: @set), notice: 'Question removed from this set. Restore brings it back.'
  end

  # DELETE /chat/models/questions/:question_id — removes an added question, or restores a built-in one as shipped.
  def destroy
    edit = TeamChat::BatteryQuestion.find_by!(set_name: @set, question_id: params[:question_id].to_s)
    builtin = TeamChat::Battery.builtin_items(TeamChat::Battery.config_for(@set)).any? { |item| item.id == edit.question_id }
    edit.destroy!
    log_change(builtin ? 'restored' : 'deleted', edit)
    redirect_to team_chat_questions_path(set: @set), notice: builtin ? 'Restored the built-in question.' : 'Question removed.'
  end

  # POST /chat/models/questions/run { set, agent }
  def run
    agent = params[:agent].to_s
    allowed = ['rupert'] + TeamChat::LocalAgents.all.map(&:handle) + (TeamChat::LocalAgents.enabled? ? TeamChat::LocalAgents::TRIALS.map(&:handle) : [])
    return redirect_to(team_chat_questions_path(set: @set), alert: 'Pick a bot that is running.') unless allowed.include?(agent)

    TeamChat::BatteryJob.perform_later(Current.user.id, @set, agent)
    ActivityLogger.log('team_chat_battery_started', actor: Current.user, details: "set=#{@set}; agent=#{agent}")
    redirect_to team_chat_questions_path(set: @set),
      notice: "Test run queued: the #{@set} questions to @#{agent}. Answers appear in its test room; the grade lands on Model scores."
  end

  private

  def require_access
    return head :forbidden unless TeamChat.allowed?(Current.user)

    authorize(:module, :dashboard_read?)
  end

  def load_set
    @set = TeamChat::Battery.sets.include?(params[:set].to_s) ? params[:set].to_s : 'default'
  end

  def save_edit(edit, notice)
    edit.assign_attributes(status: 'active', question: params[:question].to_s.strip, expect: params[:expect].to_s.strip.presence,
      cadence: params[:cadence].to_s.strip.presence || 'daily', area: params[:area].to_s.strip.presence,
      checks_json: parse_checks(params[:checks]), needs_json: params[:needs].to_s.lines.map(&:strip).compact_blank.first(12),
      updated_by: Current.user)
    if edit.save
      log_change(edit.previously_new_record? ? 'added' : 'edited', edit)
      redirect_to team_chat_questions_path(set: @set, anchor: "q-#{edit.question_id}"), notice: notice
    else
      redirect_to team_chat_questions_path(set: @set), alert: edit.errors.full_messages.to_sentence
    end
  end

  # One check per line: a tool name, then optional key=value arguments ("period_review period=yesterday").
  def parse_checks(text)
    text.to_s.lines.map(&:strip).compact_blank.first(3).map do |line|
      name, *pairs = line.split(/\s+/)
      args = pairs.filter_map { |pair| pair.split('=', 2) if pair.include?('=') }.to_h
      args.any? ? { 'tool' => name, 'args' => args } : name
    end
  end

  def next_id
    taken = TeamChat::Battery.items(TeamChat::Battery.config_for(@set)).map(&:id) + TeamChat::Battery.edits_for(@set).map(&:question_id)
    (1..999).map { |n| "w#{n}" }.find { |id| !taken.include?(id) }
  end

  def log_change(what, edit)
    ActivityLogger.log('team_chat_question_changed', actor: Current.user, details: "#{what}: #{@set}/#{edit.question_id}")
  end
end
