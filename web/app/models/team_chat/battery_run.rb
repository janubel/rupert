# frozen_string_literal: true

module TeamChat
  # One test-battery run (TeamChat::Battery): which bot and model, which question set,
  # on which Rupert build, and every question's grade, time, tools and flagged figures.
  # Shown on Model scores; the battery skips a run already done on the same model, set and build.
  class BatteryRun < ApplicationRecord
    include TenantScoped

    self.table_name = 'chat_battery_runs'
    STALE_AFTER = 2.hours

    serialize :by_cadence, coder: JSON
    serialize :results, coder: JSON

    belongs_to :room, class_name: 'TeamChat::Room', optional: true

    scope :finished, -> { where(status: 'done') }
    scope :newest_first, -> { order(started_at: :desc, id: :desc) }

    def results_list = Array(results)
    def cadence_scores = by_cadence.to_h

    # A run that stopped part-way (killed or the server restarted) shows as stopped.
    def display_status
      return status unless status == 'running'

      started_at && started_at < STALE_AFTER.ago ? 'stopped' : 'running'
    end

    def label = "@#{agent.presence || 'rupert'} · #{model.presence || 'unknown model'}"

    # Recomputes the totals from the per-question results.
    def tally!
      rows = results_list
      grades = rows.filter_map { |row| row['grade'] }
      times = rows.filter_map { |row| row['seconds'].to_f if row['seconds'].to_f.positive? }
      cadences = rows.group_by { |row| row['cadence'] }.transform_values do |list|
        scores = list.filter_map { |row| row['grade'] }
        scores.any? ? (scores.sum.to_f / scores.size).round(1) : nil
      end
      update!(answered: rows.count { |row| row['status'] == 'done' }, avg_grade: (grades.any? ? (grades.sum.to_f / grades.size).round(2) : nil),
        avg_seconds: (times.sum / times.size if times.any?), max_seconds: times.max,
        flagged: rows.count { |row| Array(row['unverified']).any? }, by_cadence: cadences)
    end

    # Each bot's latest full-set grade per question set: { ['qwen', 'qwen3.5-4b'] => { 'finance' => 4.5, 'default' => 4.1 } }.
    # A run that stopped part-way counts when it answered at least 80% of its questions.
    def self.latest_scores
      rows = where(status: %w[done stopped running]).where.not(avg_grade: nil).where.not('set_name LIKE ?', '%(part)%').newest_first.to_a
      rows.each_with_object({}) do |run, scores|
        next if run.status != 'done' && (run.display_status == 'running' || run.answered < run.questions * 0.8)

        key = [run.agent.presence || 'rupert', run.model.to_s]
        scores[key] ||= {}
        scores[key][run.set_name] ||= run.avg_grade.to_f.round(1)
      end
    end

    # The finished run for the same bot, model, question set and Rupert build, if any.
    def self.already_done(agent:, model:, set_name:, revision:)
      finished.where(agent: agent.presence, model: model, set_name: set_name, revision: revision).newest_first.first
    end

    # Rebuilds runs from #liquid-testing messages (questions, replies and grade notices carry the run key in meta).
    # Skips runs already saved. Returns the number of runs created.
    def self.backfill!(room = Room.find_by(slug: Battery::LEGACY_ROOM_SLUG))
      return 0 unless room

      messages = room.messages.where('meta LIKE ?', '%"battery"%').order(:id).to_a
      created = 0
      messages.group_by { |message| message.meta.to_h['battery'] }.each do |key, rows|
        next if key.blank? || exists?(run_key: key)

        questions = rows.select(&:person?)
        replies = rows.select(&:assistant?).index_by { |reply| reply.meta.to_h['trigger_id'] }
        grades = rows.select(&:system?).filter_map { |notice| [notice.meta.to_h['graded_message'], notice] if notice.meta.to_h['grade'] }.to_h
        next if questions.empty?

        notice = rows.find { |row| row.system? && row.body.to_s.start_with?('🧪') }
        set = notice&.body.to_s[/\((\w+) questions\)/, 1] || 'default'
        results = questions.map do |question|
          reply = replies[question.id]
          meta = reply&.meta.to_h
          grade = grades[reply&.id]
          { 'id' => question.meta.to_h['item'], 'cadence' => question.meta.to_h['cadence'], 'question' => question.body.to_s.sub(/\A@\S+\s+/, ''),
            'status' => reply&.status, 'seconds' => (meta['duration_ms'].to_f / 1000 if meta['duration_ms']), 'tools' => Array(meta['tools']),
            'grade' => grade&.meta.to_h&.dig('grade'), 'verdict' => grade&.body.to_s.lines.first.to_s.sub(/\AGrade \d\/5 for [^:]+: /, '').strip.first(300),
            'unverified' => Array(meta['unverified']), 'message_id' => reply&.id }
        end
        first_reply = replies.values.first&.meta.to_h
        done = rows.any? { |row| row.system? && row.body.to_s.start_with?('📋') }
        run = create!(run_key: key, set_name: set, agent: first_reply['agent'], model: first_reply['model'], engine: first_reply['engine'],
          status: done ? 'done' : 'stopped', questions: results.size, results: results, room: room,
          started_at: questions.first.created_at, finished_at: (rows.last.created_at if done))
        run.tally!
        created += 1
      end
      created
    end
  end
end
