# frozen_string_literal: true

module TeamChat
  # The bot leaderboard (Model scores, and the 🏆 in the chat bot key): each model's latest full run of every
  # question set, scored out of 100 per app module (Sell, Stock, Bookkeeping, Work, Team, System), for questions
  # that cross modules, and for honesty (questions with no data behind them), plus an overall score.
  # A score is the average grade (1–5) as a percentage: 4.6/5 is 92/100.
  module Leaderboard
    MODULES = { 'sell' => 'Sell', 'stock' => 'Stock', 'bookkeeping' => 'Bookkeeping', 'work' => 'Work', 'team' => 'Team',
                'system' => 'System' }.freeze
    COLUMNS = MODULES.merge('cross' => 'Cross-discipline', 'honesty' => 'Honesty').freeze
    # A model needs this many graded questions to hold the trophy.
    MIN_QUESTIONS = 20
    # A column's 🥇 needs at least this many graded questions in it.
    MIN_COLUMN = 3

    Cell = Struct.new(:score, :count, :best, keyword_init: true)
    Row = Struct.new(:model, :handle, :where, :cells, :overall, :graded, :avg_seconds, :sets, :tested_at, :leader, keyword_init: true)

    module_function

    def call
      runs = latest_runs
      rows = runs.group_by(&:model).map { |model, list| row_for(model, list) }.select { |row| row.graded.positive? }
      rows.sort_by! { |row| [-row.overall, row.avg_seconds || 9_999] }
      leader = rows.find { |row| row.graded >= MIN_QUESTIONS }
      leader.leader = true if leader
      COLUMNS.each_key do |column|
        eligible = rows.select { |row| row.cells[column] && row.cells[column].count >= MIN_COLUMN }
        top = eligible.map { |row| row.cells[column].score }.max
        eligible.each { |row| row.cells[column].best = true if row.cells[column].score == top } # ties share the medal
      end
      rows
    end

    # The model holding the trophy, or nil.
    def leader_model = call.find(&:leader)&.model

    # Each model's latest usable run per question set (full sets only; a stopped run counts once 80% answered).
    def latest_runs
      BatteryRun.where.not(model: [nil, '']).where.not('set_name LIKE ?', '%(part)%').newest_first.to_a
                .select { |run| run.status == 'done' || (run.display_status == 'stopped' && run.answered >= run.questions * 0.8) }
                .uniq { |run| [run.model, run.set_name] }
    end

    def row_for(model, runs)
      by_column = Hash.new { |hash, key| hash[key] = [] }
      graded = []
      runs.each do |run|
        run.results_list.each do |result|
          grade = result['grade']
          next unless grade

          graded << grade
          by_column[column_for(result)] << grade
        end
      end
      cells = by_column.transform_values { |grades| Cell.new(score: percent(grades), count: grades.size) }
      times = runs.filter_map(&:avg_seconds)
      Row.new(model: model, handle: handle_for(model, runs), where: runs.first.engine == 'local_gateway' ? 'local' : 'cloud',
        cells: cells, overall: (graded.any? ? percent(graded) : 0), graded: graded.size,
        avg_seconds: (times.any? ? (times.sum / times.size).round(1) : nil),
        sets: runs.map(&:set_name).sort, tested_at: runs.filter_map(&:started_at).max, leader: false)
    end

    def column_for(result)
      return 'honesty' if result['cadence'] == 'honesty'

      module_key = result['module'].presence || question_modules[result['id']]
      COLUMNS.key?(module_key) ? module_key : 'sell'
    end

    def percent(grades) = (grades.sum.to_f / grades.size / 5 * 100).round

    # Question id → module from every battery file, so older saved results without a module still count.
    def question_modules
      @question_modules = nil if Rails.env.development?
      @question_modules ||= Dir[Rails.root.join('config/team_chat/battery*.yml')].each_with_object({}) do |path, map|
        YAML.safe_load_file(path).fetch('questions').each { |row| map[row['id']] = row['module'] }
      end
    end

    # The @handle people use for this model now (a regular bot first, then a test model, @rupert for the cloud model).
    def handle_for(model, runs)
      agent = LocalAgents.all.find { |candidate| candidate.model == model } || LocalAgents::TRIALS.find { |candidate| candidate.model == model }
      return agent.handle if agent

      runs.first.agent.presence || 'rupert'
    end
  end
end
